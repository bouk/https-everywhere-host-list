#!/bin/bash
set -exuo pipefail
ruby generate.rb hosts.txt
zopfli hosts.txt
aws s3 cp ./hosts.txt.gz s3://https-all-the-things/hosts.txt --acl=public-read --content-encoding=gzip
aws cloudfront create-invalidation --distribution-id=E3EIANU9YNMH8I --paths=/hosts.txt
