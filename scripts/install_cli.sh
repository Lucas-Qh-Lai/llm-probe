#!/usr/bin/env bash
# Builds the `llmprobe` CLI in release mode and installs it on your PATH.
#
# The CLI is the same engine as the macOS app, so a terminal user or an agent
# can run every probe without opening a window.
#
# Usage:
#   scripts/install_cli.sh                 # installs into /usr/local/bin when writable, else ~/.local/bin
#   PREFIX=$HOME/.local scripts/install_cli.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Building llmprobe (release)"
swift build -c release --product llmprobe
BIN="$(swift build -c release --show-bin-path)/llmprobe"

if [ -n "${PREFIX:-}" ]; then
  TARGET_DIR="$PREFIX/bin"
elif [ -w /usr/local/bin ]; then
  TARGET_DIR="/usr/local/bin"
else
  TARGET_DIR="$HOME/.local/bin"
fi

mkdir -p "$TARGET_DIR"
install -m 0755 "$BIN" "$TARGET_DIR/llmprobe"

echo "==> Installed: $TARGET_DIR/llmprobe"
"$TARGET_DIR/llmprobe" version

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *)
    echo
    echo "Note: $TARGET_DIR is not on your PATH. Add it with:"
    echo "  echo 'export PATH=\"$TARGET_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    ;;
esac

echo
echo "Try:  llmprobe discover --json | head -40"
