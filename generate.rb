#!/usr/bin/env ruby
require 'json'
require 'nokogiri'
require 'tmpdir'

fail "Need output argument" if $*.size != 1

directory = Dir.mktmpdir
cmd = "curl -L https://github.com/EFForg/https-everywhere/archive/master.tar.gz | tar -xzf- --strip-components=5 --directory #{directory} https-everywhere-master/src/chrome/content/rules/"
system('bash', '-c', cmd)
exit $?.to_i unless $?.success?

def is_simple?(rule)
  rule.attributes['from'].value == "^http:" && rule.attributes['to'].value == "https:"
end

def write_block(file, list, regexes)
  rules = [{
    "action" => {"type" => "make-https"},
    "trigger" => {
      "url-filter" => ".*",
      "if-domain" => list
    }
  }] + (regexes.map do |reg|
    {
      "action" => {"type" => "make-https"},
      "trigger" => {
        "url-filter" => reg,
      }
    }
  end)
  IO.write(file, JSON.pretty_generate(rules))
end

def is_straightforward_rule?(from, to)
  return false unless from.start_with?("^http://")

  e = from.each_char
  "^http://".size.times { e.next }

  result = String.new("https://")
  group_count = 0
  just_closed = false
  loop do
    begin
      c = e.next
    rescue StopIteration
      break
    end
    case c
    when '('
      if e.next == '?'
        return false
      end

      group_count += 1
      result << "$#{group_count}"

      level = 1
      loop do
        previous = c
        case c = e.next
        when '('
          level += 1
        when ')'
          level -= 1
          break if level == 0
        when '|'
          return false
        end
      end
      just_closed = true
    when '?'
      return false unless just_closed
      just_closed = false
    when '$'
      begin
        e.next
        return false
      rescue StopIteration
        break
      end
    when '.', '*', '+'
      return false
    when '\\'
      result << e.next
      just_closed = false
    else
      result << c
      just_closed = false
    end
  end

  result == to
end

hosts = []

Dir["#{directory}/*.xml"].each do |name|
  doc = Nokogiri::XML(File.open(name))
  doc.xpath('//ruleset').each do |set|
    next if set.attributes['default_off']
    # TODO(bouk): run all the hosts through exclusion?
    next if set.xpath('exclusion').any?

    rules = set.xpath('rule')
    rules.each do |rule|
      from, to = rule.attributes['from'].value, rule.attributes['to'].value

      # Beautiful, beautiful logic to automatically convert regexes to straightforward hosts
      if is_straightforward_rule?(from, to)
        simpler = from.gsub('(?:', '(').gsub('\\w', '[a-z]').gsub('\\d', '[0-9]').gsub('\\S', '.').sub(/\A\^/, '').sub(/\$?\z/) {|t| t == '' ? '.*' : ''}
        if /\Ahttp:\/\/(\(www\\\.\)\?)?((\w|\\\.|\-)+)\/\.\*\z/ =~ simpler
          host = $2.gsub('\\.', '.')
          hosts << host
          hosts << "www.#{host}" if $1
        end
      end
    end

    if rules.count == 1
      rule = rules.first
      next unless is_simple?(rule)

      set.xpath('target').each do |t|
        host = t.attributes['host'].value.sub(/\A\*\./, '*')
        hosts << host
      end
    else
      set.xpath('target').each do |t|
        if t.attributes['host'].value.start_with?('*.')
          # Can't guarantee nothing breaks, might mean complicated regexes
          next 
        end

        host = t.attributes['host'].value
        u = "http://#{host}/"

        # Iterate over all the rules and if it matches one that isn't the simple rule, abort
        rules.each do |rule|
          r = Regexp.new(rule.attributes['from'].value)
          if r.match(u)
            if is_simple?(rule)
              host = t.attributes['host'].value
              hosts << host
            end
            break
          end
        end
      end
    end
  end
end

IO.write($*[0], hosts.sort.join("\n"))

$stderr.puts "Wrote #{hosts.count} hosts"
