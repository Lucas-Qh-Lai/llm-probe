#!/usr/bin/env bash
# Captures documentation screenshots from a *fictional* demo environment.
#
# Privacy: the app is pointed at an isolated state directory (--state-dir) and an
# offline demo server (scripts/demo_server.py), so no real configuration, model
# id, base URL or credential from this machine can appear in the screenshots, and
# the capture metadata written by screencapture is stripped before the files are
# committed.
#
# Robustness: macOS hands a freshly launched app to whatever stage is active and
# then *scales the window down* when Stage Manager keeps the app inactive — the
# capture still succeeds, it just produces a 300 px wide thumbnail of a 1290 px
# window. The script therefore verifies the artefact it wrote (minimum pixel
# width) and retries the whole launch when the result is a thumbnail.
#
# Usage: scripts/capture_screenshots.sh [output-directory]
#
# Writes screenshot-*.png into the output directory (docs/images by default).
# Env:   LLM_PROBE_APP           path to LLMProbe.app (default ~/Applications/LLMProbe.app)
#        LLM_PROBE_CAPTURE_DELAY seconds to let the window settle (default 10)
#        LLM_PROBE_CAPTURE_TRIES attempts per screenshot (default 4)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/docs/images}"
PORT="${LLM_PROBE_DEMO_PORT:-8899}"
APP="${LLM_PROBE_APP:-$HOME/Applications/LLMProbe.app}"
CLI="$ROOT/.build/debug/llmprobe"
APP_PROCESS='LLMProbe.app/Contents/MacOS/LLMProbe'
SETTLE="${LLM_PROBE_CAPTURE_DELAY:-10}"
TRIES="${LLM_PROBE_CAPTURE_TRIES:-5}"
# A real capture of the main window is ~2500 px wide; a Stage Manager thumbnail
# of it is ~300 px. The Settings window is smaller, so it gets its own floor.
MIN_WIDTH_MAIN=1400
MIN_WIDTH_SHEET=700

mkdir -p "$OUT"

if [ ! -d "$APP" ]; then
  echo "Build the app first: scripts/build_app.sh release" >&2
  exit 1
fi
if [ ! -x "$CLI" ]; then
  echo "Build the CLI first: swift build --product llmprobe" >&2
  exit 1
fi

# A locked screen makes this fail in a confusing way: `CGWindowListCopyWindowInfo`
# reports placeholder geometry for the app and `screencapture -l` answers
# "could not create image from window".
screen_is_locked() {
  ioreg -n Root -d1 -a 2>/dev/null | plutil -p - 2>/dev/null | grep -q '"CGSSessionScreenIsLocked" => true'
}
if screen_is_locked; then
  echo "The screen is locked. Unlock this Mac first: macOS hides window geometry and" >&2
  echo "refuses per-window captures while the login window is in front." >&2
  exit 3
fi

DEMO_HOME="$(mktemp -d "${TMPDIR:-/tmp}/llmprobe-demo.XXXXXX")"
WINDOW_TOOL="$(mktemp -d "${TMPDIR:-/tmp}/llmprobe-tools.XXXXXX")/window_id"
DEMO_SERVER_PID=""

quit_app() {
  osascript -e 'tell application "LLMProbe" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    pgrep -f "$APP_PROCESS" >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -f "$APP_PROCESS" 2>/dev/null || true
  # LaunchServices keeps a torn-down instance registered for a moment, and a new
  # instance started inside that window comes up with no window at all.
  for _ in $(seq 1 15); do
    pgrep -f "$APP_PROCESS" >/dev/null 2>&1 || break
    sleep 1
  done
  # LaunchServices needs a moment to forget the instance it just lost; a new
  # instance started too early comes up with no window at all.
  sleep 5
}

cleanup() {
  quit_app
  [ -n "$DEMO_SERVER_PID" ] && kill "$DEMO_SERVER_PID" 2>/dev/null || true
  # `find -delete` rather than rm -rf, to match the workspace rule.
  [ -d "$DEMO_HOME" ] && find "$DEMO_HOME" -depth -delete
  [ -d "$(dirname "$WINDOW_TOOL")" ] && find "$(dirname "$WINDOW_TOOL")" -depth -delete
}
trap cleanup EXIT

echo "==> Compiling the window helper"
swiftc -O "$ROOT/scripts/window_id.swift" -o "$WINDOW_TOOL"

echo "==> Starting the offline demo server on port $PORT"
python3 "$ROOT/scripts/demo_server.py" --port "$PORT" >/dev/null 2>&1 &
DEMO_SERVER_PID=$!
sleep 1.5

if ! curl -s -m 5 "http://127.0.0.1:$PORT/v1/models" >/dev/null; then
  echo "Demo server did not start." >&2
  exit 1
fi

echo "==> Seeding demo state (fictional endpoints only)"
seed() {
  local model="$1" name="$2"
  # Two runs per endpoint so the speed chart has a trend to draw.
  for _ in 1 2; do
    LLM_PROBE_HOME="$DEMO_HOME" "$CLI" probe \
      --url "http://127.0.0.1:$PORT/v1" \
      --model "$model" \
      --name "$name" \
      --plan quick --save >/dev/null 2>&1 || true
  done
}

seed "demo-small-1"    "Acme AI Gateway · demo-small-1"
seed "demo-reasoner-1" "Acme AI Gateway · demo-reasoner-1"
seed "demo-large-1"    "Acme AI Gateway · demo-large-1"

# Only ever called while our own instance is running: `tell application` would
# otherwise launch a copy *without* --state-dir, which would read the real
# profile instead of the demo one.
activate() {
  pgrep -f "$APP_PROCESS" >/dev/null 2>&1 || return 0
  osascript -e 'tell application "LLMProbe" to activate' >/dev/null 2>&1 || true
}

launch() {
  open -n "$APP" --args "$@"
  activate
}

wait_for_window() {
  local id="" tries="${LLM_PROBE_WAIT_TRIES:-45}"
  for i in $(seq 1 "$tries"); do
    sleep 1
    id="$("$WINDOW_TOOL" LLMProbe 2>/dev/null || true)"
    if [ -n "$id" ]; then
      printf '%s' "$id"
      return 0
    fi
    # A window parked in the Stage Manager strip is listed at thumbnail size (or
    # not at all); promoting the app to the active stage restores it.
    activate
    if ! pgrep -f "$APP_PROCESS" >/dev/null 2>&1 && [ "$i" -ge 5 ]; then
      echo "    the app exited during startup" >&2
      return 1
    fi
  done
  printf '%s' "$id"
}

pixel_width() {
  sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ { print $2 }'
}

# capture <file> <minimum-pixel-width> <window-env-args...>
capture() {
  local file="$1" min_width="$2" pick="${3:-largest}"
  shift 3
  local attempt=1
  while [ "$attempt" -le "$TRIES" ]; do
    echo "==> Capturing $file (attempt $attempt/$TRIES)"
    quit_app
    launch "$@"

    local id
    id="$(wait_for_window)" || true
    if [ -z "$id" ]; then
      echo "    no window appeared; retrying" >&2
      attempt=$((attempt + 1))
      continue
    fi

    if [ "$pick" = "settings" ]; then
      id="$("$WINDOW_TOOL" LLMProbe --list 2>/dev/null | awk '$2 ~ /^[0-9]+x[0-9]+$/ { split($2, d, "x"); if (d[1] < 900) { print $1; exit } }')"
    fi
    if [ -z "$id" ]; then
      echo "    the expected window was not listed; retrying" >&2
      attempt=$((attempt + 1))
      continue
    fi

    sleep "$SETTLE"
    activate
    [ -e "$file" ] && find "$file" -delete
    screencapture -x -o -l "$id" "$file" || true

    local width
    width="$(pixel_width "$file" || true)"
    if [ -n "$width" ] && [ "$width" -ge "$min_width" ]; then
      echo "    wrote $file (${width}px wide)"
      return 0
    fi
    echo "    captured ${width:-nothing}px, below the ${min_width}px floor (Stage Manager thumbnail?); retrying" >&2
    attempt=$((attempt + 1))
  done
  echo "giving up on $file after $TRIES attempts" >&2
  echo "  diagnostics: $(pgrep -fl "$APP_PROCESS" 2>/dev/null | tr '\n' ';')" >&2
  echo "  window list: $("$WINDOW_TOOL" LLMProbe --list 2>&1 | tr '\n' ';')" >&2
  return 1
}

# Eight images: a light and a dark home page, and a discovery / settings shot,
# for each of the two interface languages. Each README links only the images for
# its own language, so no Chinese capture ever appears in the English README.
#
#   zh light  screenshot-main.png / screenshot-discovery.png / screenshot-settings.png
#   en light  screenshot-main-en.png / screenshot-discovery-en.png / screenshot-settings-en.png
#   zh dark   screenshot-main-dark.png
#   en dark   screenshot-main-dark-en.png
#
# Every capture passes `--appearance` so the result never depends on whichever
# light/dark setting this Mac happens to use.
capture "$OUT/screenshot-main.png" "$MIN_WIDTH_MAIN" largest \
  --state-dir "$DEMO_HOME" --autorun --language zh --appearance light
capture "$OUT/screenshot-main-dark.png" "$MIN_WIDTH_MAIN" largest \
  --state-dir "$DEMO_HOME" --autorun --language zh --appearance dark
capture "$OUT/screenshot-main-en.png" "$MIN_WIDTH_MAIN" largest \
  --state-dir "$DEMO_HOME" --autorun --language en --appearance light
capture "$OUT/screenshot-main-dark-en.png" "$MIN_WIDTH_MAIN" largest \
  --state-dir "$DEMO_HOME" --autorun --language en --appearance dark
capture "$OUT/screenshot-discovery.png" "$MIN_WIDTH_SHEET" largest \
  --state-dir "$DEMO_HOME" --demo-discovery --show-discovery --language zh --appearance light
capture "$OUT/screenshot-discovery-en.png" "$MIN_WIDTH_SHEET" largest \
  --state-dir "$DEMO_HOME" --demo-discovery --show-discovery --language en --appearance light
capture "$OUT/screenshot-settings.png" "$MIN_WIDTH_SHEET" settings \
  --state-dir "$DEMO_HOME" --demo-discovery --language zh --appearance light --show-settings
capture "$OUT/screenshot-settings-en.png" "$MIN_WIDTH_SHEET" settings \
  --state-dir "$DEMO_HOME" --demo-discovery --language en --appearance light --show-settings

echo "==> Stripping capture metadata"
python3 "$ROOT/scripts/strip_image_metadata.py" "$OUT"/screenshot-*.png

echo "==> Done"
