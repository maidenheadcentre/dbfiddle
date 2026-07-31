#!/bin/bash

cd layer

for d in *; do
  [ -d "$d/nodejs/node_modules" ] && continue
  cd $d/nodejs
  npm i
  cd ../..
done

cd ..

for folder in site event components; do

  cd $folder

  for d in *; do
    [ -f "$d/package.json" ] || continue
    [ -d "$d/node_modules" ] && continue
    cd $d
    npm i
    cd ..
  done

  cd ..

done

scripts/cdn.sh

sam local start-api --skip-pull-image --parameter-overrides "Pass=$PGPASSWORD_LAMBDA DB=$DB_IP Certificate=$AWS_CERTIFICATE Zone=$AWS_ZONE Log=$AWS_LOG Environment=Local" --container-host host.docker.internal --host 0.0.0.0 --port 3004
