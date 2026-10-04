#!/usr/bin/env bash
# Renders the layout-critical views to PNGs without opening a window.
#
# Usage: scripts/render_layout_check.sh [output-directory]
#
# Why this exists: the published screenshots need a visible window, which needs
# an unlocked screen. `screencapture` refuses while the screen is locked and
# CGWindowList then reports geometry nobody can use, so layout regressions used
# to be unverifiable in that state. `ImageRenderer` draws in process instead, so
# this script always works and produces a file a human or an agent can inspect.
#
# Pass LLM_PROBE_CHECK_STATE=<dir> to render a populated state (endpoints and
# all) instead of the empty first-run state.
# Pass LLM_PROBE_RENDER_APPEARANCE=dark to render the dark appearance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.build/layout-check}"
BIN="${LLM_PROBE_APP_BINARY:-$ROOT/.build/debug/LLMProbeApp}"

if [ ! -x "$BIN" ]; then
  echo "Build the app first: swift build --product LLMProbeApp" >&2
  exit 1
fi

mkdir -p "$OUT"
CLEANUP=""
if [ -n "${LLM_PROBE_CHECK_STATE:-}" ]; then
  STATE="$LLM_PROBE_CHECK_STATE"
else
  STATE="$(mktemp -d "${TMPDIR:-/tmp}/llmprobe-layout-state.XXXXXX")"
  CLEANUP="$STATE"
fi

cleanup() {
  [ -n "$CLEANUP" ] && [ -d "$CLEANUP" ] && find "$CLEANUP" -depth -delete
}
trap cleanup EXIT

render() {
  local name="$1" size="$2" file="$OUT/$1.png"
  echo "==> Rendering $name at $size"
  [ -e "$file" ] && find "$file" -delete
  "$BIN" --state-dir "$STATE" --language zh --appearance light \
    --render-view "$name" --render-to "$file" --render-size "$size"
  local width
  width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')"
  local height
  height="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ {print $2}')"
  # scale 2, so a 1080x680 view has to come out 2160x1360
  local expected_w=$(( ${size%x*} * 2 ))
  local expected_h=$(( ${size#*x} * 2 ))
  if [ "$width" != "$expected_w" ] || [ "$height" != "$expected_h" ]; then
    echo "    unexpected size ${width}x${height}, wanted ${expected_w}x${expected_h}" >&2
    exit 1
  fi
  echo "    $file (${width}x${height})"
}

render empty-state 1080x680
render sidebar 300x680

echo "==> Done: $OUT"
