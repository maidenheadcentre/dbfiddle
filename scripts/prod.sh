#!/bin/bash
set -uo pipefail
scripts/cdn.sh || exit
sam build && sam deploy --stack-name fiddle-prod --resolve-s3 --capabilities CAPABILITY_IAM --parameter-overrides "Pass=$PGPASSWORD_LAMBDA Email=$ADMINEMAIL DB=10.1.0.216 Domain=dbfiddle.uk Schedule='rate(1 minute)' Certificate=$AWS_CERTIFICATE Zone=$AWS_ZONE Log=$AWS_LOG Environment=Production" --region eu-west-2
rc=$?
rm -rf .aws-sam
exit $rc