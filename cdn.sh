#!/bin/bash

components/light/node_modules/.bin/esbuild components/light/index.mjs --bundle --outfile=s3/light.js

mkdir -p build
rm -rf build/*
cd s3

for raw in *; do
  hash=$(sha256sum -zb "$raw" | cut -c1-8)
  hashed="${raw%%.*}.$hash.${raw#*.}"
  cp "$raw" ../build/"$hashed"
  pattern="${raw%%.*}\.[0-9a-f]\{8\}\.${raw#*.}"
  for f2 in ../site/*/*.mjs; do
    sed -i "s/$pattern/$hashed/g" "$f2"
  done
done

cd ../build

aws s3 sync --size-only --cache-control="max-age=31536000" . s3://mcc-fiddle-cdn

cd ..
rm -rf build
