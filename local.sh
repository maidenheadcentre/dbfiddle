#!/bin/bash

for folder in site event components; do

  cd $folder

  for d in *; do
    [ -d "$d/node_modules" ] && continue
    cd $d
    npm i
    mkdir node_modules
    cd ..
  done

  cd ..

done

./cdn.sh

sam local start-api --parameter-overrides "Pass=$PGPASSWORD_LAMBDA DB=$DB_IP Sentry=$SENTRY_DSN Certificate=$AWS_CERTIFICATE Zone=$AWS_ZONE Log=$AWS_LOG Environment=Local" --container-host host.docker.internal
