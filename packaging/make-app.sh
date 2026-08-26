#!/bin/bash
# Assembles "Agents & Repos.app" from the SPM release binary and zips it for
# a GitHub release (the cask's download). Outputs into dist/:
#   dist/Agents & Repos.app
#   dist/agentsandrepos-<version>.zip   (sha256 printed for the cask)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' \
    Sources/AgentsAndReposCore/Version.swift)
[[ -n "$VERSION" ]] || { echo "could not read Version.current" >&2; exit 1; }

swift build -c release

APP="dist/Agents & Repos.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS"
cp .build/release/agentsandrepos "$APP/Contents/MacOS/agentsandrepos"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Developer ID + hardened runtime, then notarize and staple so the
# quarantined brew download opens without any Gatekeeper prompt. Notary
# credentials are stored once via:
#   xcrun notarytool store-credentials agentsandrepos-notary \
#       --apple-id <apple-id> --team-id 5B8CP2DVHZ
# SKIP_NOTARIZE=1 produces a signed-but-unnotarized zip for local testing.
IDENTITY="Developer ID Application: Casey Haakenson (5B8CP2DVHZ)"
NOTARY_PROFILE="agentsandrepos-notary"

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

ZIP="dist/agentsandrepos-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ "${SKIP_NOTARIZE:-}" != "1" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    # Tickets staple to bundles, not zips: staple the .app, re-zip.
    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo
shasum -a 256 "$ZIP"
