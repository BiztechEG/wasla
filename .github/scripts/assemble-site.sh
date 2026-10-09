#!/usr/bin/env bash
# Puts the website together in public/: the landing page from site/, the web
# app (app/build/web) under app/ and, when it was built, the Android app under
# download/ with a version.json the landing page reads.
set -euo pipefail

rm -rf public
mkdir public
cp -r site/. public/
mkdir -p public/app
cp -r app/build/web/. public/app/
# Debug symbols for the rendering engine: never loaded by browsers.
find public/app -name '*.symbols' -delete

apk=app/build/app/outputs/flutter-apk/app-release.apk
if [ -f "$apk" ]; then
  mkdir -p public/download
  cp "$apk" public/download/wasla.apk
  version="$(sed -n 's/^version: *\([^+]*\).*/\1/p' app/pubspec.yaml)"
  printf '{"version":"%s","build":%s,"date":"%s","bytes":%s}\n' \
    "$version" "$(git rev-list --count HEAD)" "$(date -u +%F)" "$(stat -c %s "$apk")" \
    > public/download/version.json
  cat public/download/version.json
else
  echo "No APK in this build: the download button stays on \"coming soon\"."
fi
du -sh public
