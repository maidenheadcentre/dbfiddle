#!/bin/bash
./cdn.sh
sam build && sam deploy --stack-name fiddle-staging --resolve-s3 --capabilities CAPABILITY_IAM --parameter-overrides "Pass=$PGPASSWORD_LAMBDA Email=$ADMINEMAIL Sentry=$SENTRY_DSN DB=10.1.0.216 Domain=staging.dbfiddle.uk Schedule='cron(0 0 1 1 ? 1970)' Certificate=$AWS_CERTIFICATE Zone=$AWS_ZONE Log=$AWS_LOG Environment=Staging" --region eu-west-2
rm -r .aws-sam