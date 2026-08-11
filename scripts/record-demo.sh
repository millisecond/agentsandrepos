#!/bin/bash
# Records the README demo video: builds the release binary, quits the resident
# app (relaunched on exit), runs `agentsandrepos --demo` — which plays a
# scripted 40s loop of fake data (DemoTimeline) with a synthetic-cursor tour
# of the row ⋯ menu — captures the menubar + popover region with the built-in
# `screencapture` CLI, and encodes docs/demo.gif (checked in, embedded in the
# README) plus docs/demo.mp4 (gitignored; for release notes).
#
# One-time setup:
#   * Screen Recording permission for your terminal (System Settings →
#     Privacy & Security → Screen Recording). screencapture writes an empty
#     file without it; the script detects that and says so.
#   * Accessibility permission for the release binary (same pane →
#     Accessibility → add .build/release/agentsandrepos), or the ⋯-menu
#     cursor scene is skipped. Re-tick the checkbox after rebuilds.
#   * ffmpeg (brew install ffmpeg).
#
# Run on the main display and keep hands off mouse/keyboard while recording.
#
#   DURATION=40 scripts/record-demo.sh

set -euo pipefail

cd "$(dirname "$0")/.."
DURATION="${DURATION:-40}"
BINARY=".build/release/agentsandrepos"
TMP="$(mktemp -d)"
DEMO_PID=""
WAS_RUNNING=""
WAS_BUNDLE=""

cleanup() {
    [ -n "$DEMO_PID" ] && kill "$DEMO_PID" 2>/dev/null || true
    # Put the user's instance back the way we found it.
    if [ -n "$WAS_RUNNING" ]; then
        if [ -n "$WAS_BUNDLE" ]; then
            open -a "Agents & Repos" 2>/dev/null || open "$WAS_BUNDLE" 2>/dev/null || true
        else
            nohup "$BINARY" >/dev/null 2>&1 &
        fi
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

command -v ffmpeg >/dev/null || {
    echo "ffmpeg not found — brew install ffmpeg" >&2
    exit 1
}

echo "==> building release binary"
swift build -c release

# Quit any resident instance so a second menubar icon isn't in frame.
RESIDENT_PID="$(pgrep -x agentsandrepos || true)"
if [ -n "$RESIDENT_PID" ]; then
    WAS_RUNNING=1
    RESIDENT_CMD="$(ps -o comm= -p "$RESIDENT_PID" | head -1)"
    case "$RESIDENT_CMD" in
        *.app/*) WAS_BUNDLE="${RESIDENT_CMD%%.app/*}.app" ;;
    esac
    echo "==> quitting resident instance ($RESIDENT_CMD)"
    kill "$RESIDENT_PID" 2>/dev/null || true
    sleep 1
fi

echo "==> launching demo instance"
"$BINARY" --demo >"$TMP/demo.log" 2>&1 &
DEMO_PID=$!

REGION=""
for _ in $(seq 1 60); do
    REGION="$(sed -n 's/^DEMO_READY region=//p' "$TMP/demo.log" | head -1)"
    [ -n "$REGION" ] && break
    kill -0 "$DEMO_PID" 2>/dev/null || break
    sleep 0.25
done
if grep -q DEMO_NEEDS_AX "$TMP/demo.log"; then
    echo "--- demo instance wants Accessibility (⋯-menu scene will be skipped):" >&2
    sed -n '/DEMO_NEEDS_AX/,/per-binary/p' "$TMP/demo.log" >&2
fi
if [ -z "$REGION" ]; then
    echo "demo instance never printed DEMO_READY; log follows:" >&2
    cat "$TMP/demo.log" >&2
    exit 1
fi

echo "==> recording ${DURATION}s of region $REGION (don't touch mouse/keyboard)"
# || true: screencapture exits non-zero when Screen Recording is denied,
# and under set -e that would skip the explanation below.
screencapture -v -C -R"$REGION" -V "$DURATION" "$TMP/demo.mov" || true

if [ ! -s "$TMP/demo.mov" ] || [ "$(stat -f%z "$TMP/demo.mov")" -lt 100000 ]; then
    cat >&2 <<'EOF'
Recording came out empty — almost always the Screen Recording permission:
  System Settings → Privacy & Security → Screen Recording → enable the
  terminal app you ran this from, then re-run the script (macOS may ask
  you to relaunch the terminal first).
EOF
    exit 1
fi

kill "$DEMO_PID" 2>/dev/null || true
DEMO_PID=""

mkdir -p docs
echo "==> encoding docs/demo.mp4"
# trunc(iw/4)*2 halves the Retina 2x capture and forces even dims for H.264.
ffmpeg -y -loglevel error -i "$TMP/demo.mov" \
    -vf "scale=trunc(iw/4)*2:trunc(ih/4)*2" \
    -c:v libx264 -crf 20 -pix_fmt yuv420p -movflags +faststart docs/demo.mp4

echo "==> encoding docs/demo.gif"
ffmpeg -y -loglevel error -i "$TMP/demo.mov" \
    -vf "fps=10,scale=trunc(iw/4)*2:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    docs/demo.gif

du -h docs/demo.mp4 docs/demo.gif
GIF_BYTES="$(stat -f%z docs/demo.gif)"
if [ "$GIF_BYTES" -gt 5000000 ]; then
    echo "warning: GIF over 5MB — try fps=8 in the palette filter, a shorter DURATION, or a tighter region" >&2
fi
echo "done."
