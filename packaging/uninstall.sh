#!/bin/bash
# Removes every trace of Agents & Repos from this machine — for testing clean
# installs. Covers: the SMAppService login item, running processes, the brew
# cask (and legacy formula/service), app bundles in /Applications, stray CLI
# symlinks, preferences, ~/.config state, per-app Library dirs, and TCC
# permission grants (Apple Events, Accessibility).
#
# Deliberately NOT removed:
#   - the repo's local build artifacts (dist/, .build/) — dev workspace
#   - the millisecond/tap brew tap (`brew untap millisecond/tap` if wanted)
#   - the Gatekeeper "Open Anyway" approval (macOS has no per-app reset)
set -uo pipefail

BUNDLE_ID="com.millisecond.agentsandrepos"
APP_NAME="Agents & Repos.app"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n==> %s\n' "$1"; }

# 1. Unregister the login item while a bundle still exists to do it. Any of
#    these bundles may be the one that registered; unregister is idempotent.
step "Unregistering login item"
found_bundle=0
for app in "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME" "$REPO_DIR/dist/$APP_NAME"; do
    bin="$app/Contents/MacOS/agentsandrepos"
    if [[ -x "$bin" ]]; then
        found_bundle=1
        echo "via $app:"
        "$bin" unregister-login || true
    fi
done
[[ $found_bundle -eq 1 ]] || echo "no app bundle found; nothing to unregister"

# 2. Kill running instances (menubar app or bare release binary).
step "Killing running instances"
if pkill -x agentsandrepos 2>/dev/null; then
    echo "killed"
    sleep 1
else
    echo "none running"
fi

# 3. Legacy formula-era brew service, if it survived the cask migration.
step "Removing legacy brew-services launch agent"
launchctl bootout "gui/$(id -u)/homebrew.mxcl.agentsandrepos" 2>/dev/null \
    && echo "booted out launchd service" || true
rm -fv "$HOME/Library/LaunchAgents/homebrew.mxcl.agentsandrepos.plist"

# 4. Homebrew: current cask (zap runs its trash list too) and legacy formula.
if command -v brew >/dev/null 2>&1; then
    step "Uninstalling from Homebrew"
    if brew list --cask agentsandrepos >/dev/null 2>&1; then
        brew uninstall --cask --zap agentsandrepos
    else
        echo "cask not installed"
    fi
    if brew list --formula agentsandrepos >/dev/null 2>&1; then
        brew uninstall --formula agentsandrepos
    fi
fi

# 5. App bundles installed outside brew.
step "Removing app bundles"
for app in "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"; do
    [[ -d "$app" ]] && rm -rfv "$app"
done
echo "done"

# 6. Stray CLI symlinks pointing at the app or a build of it.
step "Removing CLI symlinks"
for link in /usr/local/bin/agentsandrepos /opt/homebrew/bin/agentsandrepos; do
    if [[ -L "$link" ]]; then
        target=$(readlink "$link")
        case "$target" in
            *agentsandrepos*) rm -fv "$link" ;;
        esac
    fi
done
echo "done"

# 7. Preferences. The bundled app uses the bundle-id domain; a bare
#    `swift build` binary writes under the process name instead.
step "Deleting preferences (install ID, etc.)"
defaults delete "$BUNDLE_ID" 2>/dev/null && echo "deleted $BUNDLE_ID" || true
defaults delete agentsandrepos 2>/dev/null && echo "deleted agentsandrepos" || true
rm -fv "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
       "$HOME/Library/Preferences/agentsandrepos.plist"

# 8. Config, single-instance lock, and per-app Library dirs.
step "Deleting config and Library state"
rm -rfv "$HOME/.config/agentsandrepos" \
        "$HOME/Library/Caches/$BUNDLE_ID" \
        "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
        "$HOME/Library/Application Support/$BUNDLE_ID" \
        "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
        "$HOME/Library/WebKit/$BUNDLE_ID"

# 9. TCC grants (Apple Events for terminal focus, Accessibility for AX raise).
step "Resetting TCC permission grants"
tccutil reset AppleEvents "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true

# 10. Verify.
step "Verifying"
leftovers=0
if pgrep -x agentsandrepos >/dev/null; then
    echo "STILL RUNNING: $(pgrep -x agentsandrepos | tr '\n' ' ')"
    leftovers=1
fi
for p in "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME" \
         "$HOME/.config/agentsandrepos" \
         "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
         "$HOME/Library/LaunchAgents/homebrew.mxcl.agentsandrepos.plist"; do
    if [[ -e "$p" ]]; then
        echo "STILL PRESENT: $p"
        leftovers=1
    fi
done
if [[ $leftovers -eq 0 ]]; then
    echo "clean — no traces found"
else
    echo "some traces remain (see above)"
fi
echo
echo "Manual check: System Settings → General → Login Items should no longer"
echo "list Agents & Repos (sudo sfltool dumpbtm | grep -i agentsandrepos to"
echo "verify from the shell). Local dev artifacts (dist/, .build/) were kept."
