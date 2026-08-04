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

# Ad-hoc signature: enough to run locally and register SMAppService login
# items. The quarantined brew download still hits Gatekeeper on first open —
# see the cask caveats.
codesign --force --sign - "$APP"

ZIP="dist/agentsandrepos-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo
shasum -a 256 "$ZIP"
