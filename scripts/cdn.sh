#!/bin/bash
set -euo pipefail

components/codemirror/node_modules/.bin/rollup components/codemirror/build.js --format iife --name cm --file s3/codemirror.js --plugin @rollup/plugin-node-resolve
components/light/node_modules/.bin/esbuild s3/codemirror.js --minify --allow-overwrite --outfile=s3/codemirror.js
components/light/node_modules/.bin/esbuild components/light/index.mjs --bundle --minify --outfile=s3/light.js

rm -rf build
mkdir -p build/static
cd s3

for raw in *; do
  hash=$(sha256sum -zb "$raw" | cut -c1-8)
  hashed="${raw%%.*}.$hash.${raw#*.}"
  cp "$raw" ../build/static/"$hashed"
  pattern="${raw%%.*}\.[0-9a-f]\{8\}\.${raw#*.}"
  for f2 in ../site/*/*.mjs; do
    sed -i "s/$pattern/$hashed/g" "$f2"
  done
done

cd ../build/static

aws s3 sync --size-only --cache-control="public, max-age=31536000, immutable" . s3://mcc-fiddle-cdn
