#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# Packages a signed iOS release: runs the unit tests, archives the app, checks it is signed with a
# distribution certificate and points at an https pack manifest, exports an .ipa and copies it with
# the debug symbols to ios/dist/ with the version in the name.
#
# The Apple Developer team comes from the first of:
#   1. ios/signing.properties (never committed) with developmentTeam, and for --upload also
#      appStoreConnectKeyId, appStoreConnectIssuerId and appStoreConnectKeyFile
#   2. RAILMAP_DEVELOPMENT_TEAM in ios/Config/Signing.local.xcconfig, the same gitignored file Xcode
#      reads, so a solo developer sets the team in one place and nothing else is needed
#   3. the RELEASE_DEVELOPMENT_TEAM, RELEASE_ASC_KEY_ID, RELEASE_ASC_ISSUER_ID and
#      RELEASE_ASC_KEY_FILE environment variables
#   4. 1Password, through the op CLI: the item RELEASE_IOS_1PASSWORD_ITEM (default below) with a
#      "team id" field, and for --upload a "key id" field, an "issuer id" field and the App Store
#      Connect key as the file "AuthKey.p8". The key is read into a temporary folder that is
#      removed when the script exits.
#
# The signing certificate and provisioning profile come from the login keychain, as they do in
# Xcode; --allowProvisioningUpdates lets Xcode fetch or renew the profile when it is missing.
#
# Usage: scripts/package-ios-release.sh [--skip-tests] [--allow-dirty] [--adhoc] [--upload] [--yes]
set -euo pipefail

cd "$(dirname "$0")/../ios"

skip_tests=false
allow_dirty=false
adhoc=false
upload=false
assume_yes=false
for arg in "$@"; do
    case "$arg" in
        --skip-tests) skip_tests=true ;;
        --allow-dirty) allow_dirty=true ;;
        --adhoc) adhoc=true ;;
        --upload) upload=true ;;
        --yes) assume_yes=true ;;
        *) echo "usage: package-ios-release.sh [--skip-tests] [--allow-dirty] [--adhoc] [--upload] [--yes]" >&2; exit 2 ;;
    esac
done

fail() {
    echo "error: $*" >&2
    exit 1
}

if $adhoc && $upload; then
    fail "--adhoc builds cannot be uploaded to App Store Connect"
fi

# Xcode proper, not just the command line tools, is needed to archive.
command -v xcodebuild >/dev/null || fail "xcodebuild not found; install Xcode"
developer_dir=$(xcode-select -p)
case "$developer_dir" in
    *CommandLineTools*) fail "xcode-select points at $developer_dir; run: sudo xcode-select -s /Applications/Xcode.app" ;;
esac

# Release builds should be reproducible from a commit.
if ! $allow_dirty && [ -n "$(git status --porcelain -- .)" ]; then
    git status --short -- .
    fail "ios/ has uncommitted changes; commit them or pass --allow-dirty"
fi

op_item="${RELEASE_IOS_1PASSWORD_ITEM:-op://Private/Offline Rail Map iOS signing}"
props=signing.properties
read_prop() {
    [ -f "$props" ] || return 0
    sed -nE "s/^$1=(.*)$/\1/p" "$props"
}

local_xcconfig=Config/Signing.local.xcconfig

team_id=$(read_prop developmentTeam)
if [ -z "$team_id" ] && [ -f "$local_xcconfig" ]; then
    # Same file Xcode reads, so the team only has to be written down once.
    team_id=$(sed -nE 's|^[[:space:]]*RAILMAP_DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([^/[:space:]]+).*|\1|p' "$local_xcconfig" | tail -1)
fi
asc_key_id=$(read_prop appStoreConnectKeyId)
asc_issuer_id=$(read_prop appStoreConnectIssuerId)
asc_key_file=$(read_prop appStoreConnectKeyFile)
: "${team_id:=${RELEASE_DEVELOPMENT_TEAM:-}}"
: "${asc_key_id:=${RELEASE_ASC_KEY_ID:-}}"
: "${asc_issuer_id:=${RELEASE_ASC_ISSUER_ID:-}}"
: "${asc_key_file:=${RELEASE_ASC_KEY_FILE:-}}"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

if [ -z "$team_id" ] && command -v op >/dev/null; then
    echo "Reading the signing details from 1Password ($op_item)"
    team_id=$(op read --no-newline "$op_item/team id") ||
        fail "could not read the team id from $op_item"
fi
[ -n "$team_id" ] || fail "no Apple Developer team configured; see the top of $0"

if $upload && [ -z "$asc_key_id" ] && command -v op >/dev/null; then
    asc_key_id=$(op read --no-newline "$op_item/key id")
    asc_issuer_id=$(op read --no-newline "$op_item/issuer id")
    asc_key_file="$work_dir/private_keys/AuthKey_$asc_key_id.p8"
    mkdir -p "$work_dir/private_keys"
    op read --force --out-file "$asc_key_file" "$op_item/AuthKey.p8" >/dev/null ||
        fail "could not read the App Store Connect key from $op_item"
fi
if $upload; then
    [ -n "$asc_key_id" ] && [ -n "$asc_issuer_id" ] && [ -n "$asc_key_file" ] ||
        fail "--upload needs an App Store Connect API key; see the top of $0"
    [ -f "$asc_key_file" ] || fail "App Store Connect key $asc_key_file does not exist"
    # altool looks the key up by name in API_PRIVATE_KEYS_DIR rather than reading the path.
    [ "$(basename "$asc_key_file")" = "AuthKey_$asc_key_id.p8" ] ||
        fail "the App Store Connect key must be named AuthKey_$asc_key_id.p8, not $(basename "$asc_key_file")"
fi

version_name=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = (.*);$/\1/p' OfflineRailwayMap.xcodeproj/project.pbxproj | head -1)
build_number=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = (.*);$/\1/p' OfflineRailwayMap.xcodeproj/project.pbxproj | head -1)
[ -n "$version_name" ] && [ -n "$build_number" ] || fail "could not read the version from the Xcode project"
echo "Packaging Offline Rail Map $version_name (build $build_number) for team $team_id"

if ! $skip_tests; then
    # The logic shared with the app lives in RailwayMapCore, where the unit tests are.
    swift test --package-path RailwayMapCore
fi

archive="$work_dir/OfflineRailwayMap.xcarchive"
xcodebuild archive \
    -project OfflineRailwayMap.xcodeproj \
    -scheme OfflineRailwayMap \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    RAILMAP_DEVELOPMENT_TEAM="$team_id"

app="$archive/Products/Applications/OfflineRailwayMap.app"
[ -d "$app" ] || fail "the archive has no app at $app"

# A MANIFEST_URL override in a local xcconfig must not reach a release.
manifest_url=$(/usr/libexec/PlistBuddy -c "Print :ManifestURL" "$app/Info.plist")
case "$manifest_url" in
    https://*) ;;
    *) fail "release build reads its packs from '$manifest_url', which is not https" ;;
esac

# Apple rejects a build whose export compliance answer is missing.
/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$app/Info.plist" >/dev/null 2>&1 ||
    fail "Info.plist is missing ITSAppUsesNonExemptEncryption"

if $adhoc; then
    method=release-testing
else
    method=app-store-connect
fi
export_options="$work_dir/ExportOptions.plist"
sed -e "s/__METHOD__/$method/" -e "s/__TEAM_ID__/$team_id/" Config/ExportOptions.plist > "$export_options"

xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$export_options" \
    -exportPath "$work_dir/export" \
    -allowProvisioningUpdates

ipa=$(ls -1 "$work_dir/export"/*.ipa 2>/dev/null | head -1 || true)
[ -n "$ipa" ] || fail "the export produced no .ipa"

# Check what actually ships, not just the archive: unpack the .ipa and verify its signature.
unzip -q "$ipa" -d "$work_dir/unpacked"
exported_app=$(ls -1d "$work_dir/unpacked/Payload"/*.app | head -1)
codesign --verify --strict "$exported_app" || fail "$ipa is not correctly signed"
authority=$(codesign -dvv "$exported_app" 2>&1 | sed -nE 's/^Authority=(Apple Distribution.*|iPhone Distribution.*)$/\1/p' | head -1)
[ -n "$authority" ] || fail "$ipa is not signed with a distribution certificate"

mkdir -p dist
dist_dir="$PWD/dist"
name="offline-rail-map-$version_name"
if $adhoc; then
    name="$name-adhoc"
fi
cp "$ipa" "$dist_dir/$name.ipa"
# Keep the debug symbols: they are what symbolicates a crash report from this build.
[ -d "$archive/dSYMs" ] || fail "the archive has no dSYMs; is DEBUG_INFORMATION_FORMAT still dwarf-with-dsym?"
(cd "$archive" && zip -qr "$dist_dir/$name-dSYMs.zip" dSYMs)

echo
echo "Manifest URL:     $manifest_url"
echo "Signing key:      $authority"
echo "Export method:    $method"
(cd dist && shasum -a 256 "$name.ipa" "$name-dSYMs.zip")
echo
echo "Wrote ios/dist/$name.ipa and ios/dist/$name-dSYMs.zip"

if $upload; then
    echo
    if ! $assume_yes; then
        # An upload burns this build number in App Store Connect and cannot be undone.
        printf 'Upload %s to App Store Connect as build %s? [y/N] ' "$name.ipa" "$build_number"
        read -r reply || reply=""
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "Not uploading."; exit 0 ;;
        esac
    fi
    API_PRIVATE_KEYS_DIR=$(dirname "$asc_key_file") \
        xcrun altool --upload-app -f "dist/$name.ipa" -t ios \
            --apiKey "$asc_key_id" --apiIssuer "$asc_issuer_id"
    echo "Uploaded; it appears in App Store Connect once Apple finishes processing it."
fi
