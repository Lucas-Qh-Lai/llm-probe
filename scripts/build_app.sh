#!/usr/bin/env bash
# Builds LLMProbe.app: a self-contained, ad-hoc signed macOS application bundle.
#
# Usage: scripts/build_app.sh [debug|release] [output-directory] [native|arm64|x86_64]
set -euo pipefail

CONFIGURATION="${1:-release}"
# The default output lives outside the repository on purpose: if the checkout is
# inside a cloud-synced folder, the file provider re-adds Finder metadata and the
# ad-hoc signature stops verifying, which makes macOS kill the app on launch.
OUTPUT_DIR="${2:-$HOME/Applications}"
TARGET_ARCH="${3:-native}"
case "$TARGET_ARCH" in
  native|arm64|x86_64) ;;
  *) echo "Unsupported architecture: $TARGET_ARCH (use native, arm64 or x86_64)" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Single source of truth for the version: LLMProbeVersion.short. Keeping the
# Info.plist in sync by hand is how a bundle ends up reporting the last release.
VERSION="$(sed -nE 's/.*public static let short = "([^"]+)".*/\1/p' \
  "$ROOT/Sources/LLMProbeCore/Providers/EndpointResolver.swift" | head -1)"
VERSION="${VERSION:-0.0.0}"

BUILD_ARGS=(-c "$CONFIGURATION")
if [ "$TARGET_ARCH" != "native" ]; then
  BUILD_ARGS+=(--arch "$TARGET_ARCH")
fi

echo "==> Building $CONFIGURATION binary for $TARGET_ARCH (LLMProbe $VERSION)"
swift build "${BUILD_ARGS[@]}" --product LLMProbeApp

BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
case "$OUTPUT_DIR" in
  /*) APP_PARENT="$OUTPUT_DIR" ;;
  *)  APP_PARENT="$ROOT/$OUTPUT_DIR" ;;
esac
APP_DIR="$APP_PARENT/LLMProbe.app"

# Assemble inside a staging directory that is not managed by a cloud file
# provider: those re-add Finder metadata, and codesign refuses to sign a bundle
# that carries it ("resource fork, Finder information ... not allowed").
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/llmprobe-app.XXXXXX")"
STAGED_APP="$STAGE/LLMProbe.app"
CONTENTS="$STAGED_APP/Contents"

echo "==> Assembling $STAGED_APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp -X "$BIN_PATH/LLMProbeApp" "$CONTENTS/MacOS/LLMProbe"

ACTUAL_ARCHS="$(lipo -archs "$CONTENTS/MacOS/LLMProbe")"
if [ "$TARGET_ARCH" = "arm64" ] && [ "$ACTUAL_ARCHS" != "arm64" ]; then
  echo "Architecture mismatch: expected arm64, got $ACTUAL_ARCHS" >&2
  exit 1
fi
if [ "$TARGET_ARCH" = "x86_64" ] && [ "$ACTUAL_ARCHS" != "x86_64" ]; then
  echo "Architecture mismatch: expected x86_64, got $ACTUAL_ARCHS" >&2
  exit 1
fi
echo "    binary architecture: $ACTUAL_ARCHS"

if [ ! -f "$ROOT/docs/images/AppIcon.icns" ]; then
  echo "==> Generating app icon"
  python3 "$ROOT/scripts/make_icon.py" "$ROOT/docs/images/AppIcon.icns"
fi
cp -X "$ROOT/docs/images/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LLMProbe</string>
  <key>CFBundleDisplayName</key><string>LLMProbe</string>
  <key>CFBundleIdentifier</key><string>dev.llmprobe.app</string>
  <key>CFBundleExecutable</key><string>LLMProbe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. Runs fully offline.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
signed=0
for attempt in 1 2 3 4; do
  xattr -cr "$STAGED_APP" 2>/dev/null || true
  if codesign --force --deep --sign - "$STAGED_APP" >/dev/null 2>&1; then
    signed=1
    break
  fi
  sleep 0.4
done

if [ "$signed" -eq 1 ] && codesign --verify --deep --strict "$STAGED_APP" 2>/dev/null; then
  echo "    signature verified"
else
  echo "    WARNING: ad-hoc signing failed after retries; macOS may refuse to launch the app" >&2
fi

echo "==> Installing to $APP_DIR"
mkdir -p "$APP_PARENT"
if [ -d "$APP_DIR" ]; then
  find "$APP_DIR" -depth -delete
fi
ditto --norsrc --noextattr --noqtn "$STAGED_APP" "$APP_DIR"
find "$STAGE" -depth -delete 2>/dev/null || true

if ! codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
  echo "    WARNING: the installed copy no longer verifies; run:" >&2
  echo "    xattr -cr \"$APP_DIR\" && codesign --force --deep --sign - \"$APP_DIR\"" >&2
fi

echo "==> Done: $APP_DIR"
echo "    Launch with: open \"$APP_DIR\""
