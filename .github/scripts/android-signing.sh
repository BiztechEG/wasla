#!/usr/bin/env bash
# Picks the key the Android release build is signed with (read by
# app/android/app/build.gradle.kts through WASLA_KEYSTORE_FILE and
# WASLA_KEY_PASSWORD).
#
# With the ANDROID_KEYSTORE and ANDROID_KEY_PASSWORD secrets set, that is the
# app's own key (made once by the "Create Android signing key" workflow), so
# phones can update from one build to the next. Without them, a throwaway key
# is made for this build only, which is fine for test builds.
# Writes release=true or release=false to the step's outputs.
set -euo pipefail

file="$RUNNER_TEMP/wasla-signing.p12"
if [ -n "${ANDROID_KEYSTORE:-}" ] && [ -n "${ANDROID_KEY_PASSWORD:-}" ]; then
  # A copied secret may carry line breaks; base64 doesn't mind, \r does.
  printf '%s' "$ANDROID_KEYSTORE" | tr -d '\r\n ' | base64 -d > "$file"
  password="$ANDROID_KEY_PASSWORD"
  if ! keytool -list -keystore "$file" -storepass "$password" -alias wasla >/dev/null 2>&1; then
    echo "::error::ANDROID_KEYSTORE can't be opened with ANDROID_KEY_PASSWORD, or has no 'wasla' key. Check both secrets."
    exit 1
  fi
  echo "release=true" >> "$GITHUB_OUTPUT"
else
  password="$(openssl rand -hex 24)"
  keytool -genkeypair -storetype PKCS12 -keystore "$file" -alias wasla \
    -keyalg RSA -keysize 2048 -validity 30 -storepass "$password" \
    -dname "CN=Wasla test build" >/dev/null 2>&1
  echo "No release key yet: this build is signed with a throwaway key."
  echo "release=false" >> "$GITHUB_OUTPUT"
fi
echo "::add-mask::$password"
{
  echo "WASLA_KEYSTORE_FILE=$file"
  echo "WASLA_KEY_PASSWORD=$password"
} >> "$GITHUB_ENV"
