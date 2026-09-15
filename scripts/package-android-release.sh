#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# Packages a signed Android release: runs the unit tests, builds the Play bundle (.aab) and an
# installable .apk, checks both are signed and point at an https pack manifest, and copies them to
# android/dist/ with the version in the name.
#
# The upload key comes from the first of:
#   1. android/keystore.properties (never committed) with storeFile, storePassword, keyAlias, keyPassword
#   2. the RELEASE_STORE_FILE, RELEASE_STORE_PASSWORD, RELEASE_KEY_ALIAS and RELEASE_KEY_PASSWORD
#      environment variables
#   3. 1Password, through the op CLI: the item RELEASE_1PASSWORD_ITEM (default below) holding the
#      keystore as the file "keystore", its password and a "key alias" field. The keystore is read
#      into a temporary folder that is removed when the script exits.
#
# Usage: scripts/package-android-release.sh [--skip-tests] [--allow-dirty]
set -euo pipefail

cd "$(dirname "$0")/../android"

skip_tests=false
allow_dirty=false
for arg in "$@"; do
    case "$arg" in
        --skip-tests) skip_tests=true ;;
        --allow-dirty) allow_dirty=true ;;
        *) echo "usage: package-android-release.sh [--skip-tests] [--allow-dirty]" >&2; exit 2 ;;
    esac
done

fail() {
    echo "error: $*" >&2
    exit 1
}

# Gradle needs JDK 21; fall back to an SDKMAN install when JAVA_HOME is not set.
if [ -z "${JAVA_HOME:-}" ]; then
    for candidate in "$HOME"/.sdkman/candidates/java/21*; do
        if [ -x "$candidate/bin/java" ]; then
            export JAVA_HOME="$candidate"
        fi
    done
fi
[ -n "${JAVA_HOME:-}" ] || fail "set JAVA_HOME to a JDK 21"
java_major=$("$JAVA_HOME/bin/java" -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p' | head -1)
[ "${java_major:-0}" -ge 21 ] || fail "JAVA_HOME ($JAVA_HOME) is JDK $java_major; Gradle needs 21 or newer"

# Release builds should be reproducible from a commit.
if ! $allow_dirty && [ -n "$(git status --porcelain -- .)" ]; then
    git status --short -- .
    fail "android/ has uncommitted changes; commit them or pass --allow-dirty"
fi

op_item="${RELEASE_1PASSWORD_ITEM:-op://Private/Offline Rail Map Android upload key}"
if [ -f keystore.properties ]; then
    store_file=$(sed -nE 's/^storeFile=(.*)$/\1/p' keystore.properties)
elif [ -n "${RELEASE_STORE_FILE:-}" ]; then
    store_file="$RELEASE_STORE_FILE"
elif command -v op >/dev/null; then
    echo "Reading the upload key from 1Password ($op_item)"
    key_dir=$(mktemp -d)
    trap 'rm -rf "$key_dir"' EXIT
    op read --force --out-file "$key_dir/upload.jks" "$op_item/keystore" >/dev/null ||
        fail "could not read the keystore from $op_item"
    RELEASE_STORE_PASSWORD=$(op read --no-newline "$op_item/password")
    RELEASE_KEY_ALIAS=$(op read --no-newline "$op_item/key alias")
    export RELEASE_STORE_FILE="$key_dir/upload.jks" RELEASE_STORE_PASSWORD RELEASE_KEY_ALIAS
    export RELEASE_KEY_PASSWORD="$RELEASE_STORE_PASSWORD"
    store_file="$RELEASE_STORE_FILE"
else
    store_file=""
fi
[ -n "$store_file" ] || fail "no signing key configured; see the top of $0"
case "$store_file" in
    /*) ;;
    *) store_file="$PWD/$store_file" ;;
esac
[ -f "$store_file" ] || fail "keystore $store_file does not exist"

sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$sdk_dir" ] && [ -f local.properties ]; then
    sdk_dir=$(sed -nE 's/^sdk\.dir=(.*)$/\1/p' local.properties)
fi
apksigner=$(ls -d "$sdk_dir"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)
[ -x "$apksigner" ] || fail "apksigner not found in $sdk_dir/build-tools; set ANDROID_HOME"

apksign() {
    # Keeps newer JDKs quiet about apksigner loading its native library.
    "$apksigner" -J-enable-native-access=ALL-UNNAMED "$@"
}

version_name=$(sed -nE 's/^ *versionName = "(.*)"$/\1/p' app/build.gradle.kts)
version_code=$(sed -nE 's/^ *versionCode = ([0-9]+)$/\1/p' app/build.gradle.kts)
echo "Packaging Offline Rail Map $version_name (version code $version_code)"

tasks=(:app:bundleRelease :app:assembleRelease)
if ! $skip_tests; then
    # AGP only creates unit tests for the debug variant; they cover the same code.
    tasks=(:app:testDebugUnitTest "${tasks[@]}")
fi
./gradlew "${tasks[@]}"

# A manifestUrl override (for example in ~/.gradle/gradle.properties) must not reach a release.
build_config=app/build/generated/source/buildConfig/release/com/offlinerailmap/android/BuildConfig.java
manifest_url=$(sed -nE 's/.*MANIFEST_URL = "(.*)";/\1/p' "$build_config")
case "$manifest_url" in
    https://*) ;;
    *) fail "release build reads its packs from '$manifest_url', which is not https" ;;
esac

aab=app/build/outputs/bundle/release/app-release.aab
apk=app/build/outputs/apk/release/app-release.apk
apksign verify "$apk" || fail "$apk is not signed"
"$JAVA_HOME/bin/jarsigner" -verify "$aab" | grep -q "jar verified" || fail "$aab is not signed"

mkdir -p dist
name="offline-rail-map-$version_name"
cp "$aab" "dist/$name.aab"
cp "$apk" "dist/$name.apk"

echo
echo "Manifest URL:     $manifest_url"
apksign verify --print-certs "dist/$name.apk" | sed -nE 's/^Signer #1 certificate (DN|SHA-256 digest): /Signing key \1: /p'
(cd dist && shasum -a 256 "$name.aab" "$name.apk")
echo
echo "Wrote android/dist/$name.aab (upload to Google Play) and android/dist/$name.apk"
