#!/bin/bash
mkdir -p build
rm -rf build/*
cp codemirror/build.js build
cd build
npm i codemirror
npm i @codemirror/language
npm i @codemirror/lang-javascript
npm i @codemirror/lang-sql
npm i rollup @rollup/plugin-node-resolve
node_modules/.bin/rollup build.js --format iife --name cm --file ../s3/codemirror.js --plugin @rollup/plugin-node-resolve
cd ..
./cdn.sh