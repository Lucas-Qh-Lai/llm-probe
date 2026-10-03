#!/usr/bin/env bash
# Builds shippable macOS artifacts for Apple silicon and Intel:
#   dist/LLMProbe-<version>-macOS-ARM64.zip
#   dist/LLMProbe-<version>-macOS-Intel-x86_64.zip
# plus one .sha256 per zip and a combined SHA256SUMS file.
#
# Usage: scripts/package_release.sh [version]
#
# App bundles are assembled outside the checkout (scripts/build_app.sh) because
# a cloud-synced folder re-adds Finder metadata and breaks ad-hoc signatures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Single source of truth for the version: LLMProbeVersion.short.
DEFAULT_VERSION="$(sed -nE 's/.*public static let short = "([^"]+)".*/\1/p' \
  Sources/LLMProbeCore/Providers/EndpointResolver.swift | head -1)"
VERSION="${1:-${DEFAULT_VERSION:-0.0.0}}"

mkdir -p "$ROOT/dist"
# Remove the former ambiguous single-architecture name so a stale asset cannot
# be published by mistake.
LEGACY="$ROOT/dist/LLMProbe-$VERSION.zip"
[ -e "$LEGACY" ] && find "$LEGACY" -delete
[ -e "$LEGACY.sha256" ] && find "$LEGACY.sha256" -delete

package_arch() {
  local swift_arch="$1" label="$2"
  local stage zip app actual
  stage="$(mktemp -d "${TMPDIR:-/tmp}/llmprobe-package-$label.XXXXXX")"
  zip="$ROOT/dist/LLMProbe-$VERSION-macOS-$label.zip"

  echo "==> Building $label"
  if ! "$ROOT/scripts/build_app.sh" release "$stage" "$swift_arch"; then
    find "$stage" -depth -delete
    return 1
  fi

  app="$stage/LLMProbe.app"
  if ! codesign --verify --deep --strict "$app"; then
    echo "Signature verification failed for $label" >&2
    find "$stage" -depth -delete
    return 1
  fi
  actual="$(lipo -archs "$app/Contents/MacOS/LLMProbe")"
  if [ "$actual" != "$swift_arch" ]; then
    echo "Architecture verification failed for $label: $actual" >&2
    find "$stage" -depth -delete
    return 1
  fi

  [ -e "$zip" ] && find "$zip" -delete
  [ -e "$zip.sha256" ] && find "$zip.sha256" -delete

  echo "==> Zipping $zip"
  # `--sequesterRsrc` keeps extended attributes out of the archive so the ad-hoc
  # signature survives the download/unzip round trip.
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
  ( cd "$ROOT/dist" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256" )
  find "$stage" -depth -delete
}

package_arch arm64 ARM64
package_arch x86_64 Intel-x86_64

echo "==> Combined checksums"
(
  cd "$ROOT/dist"
  cat "LLMProbe-$VERSION-macOS-ARM64.zip.sha256" \
      "LLMProbe-$VERSION-macOS-Intel-x86_64.zip.sha256" > "LLMProbe-$VERSION-SHA256SUMS"
)

echo "==> Done"
ls -lh "$ROOT/dist/LLMProbe-$VERSION"-macOS-*.zip "$ROOT/dist/LLMProbe-$VERSION"-macOS-*.zip.sha256 "$ROOT/dist/LLMProbe-$VERSION-SHA256SUMS"
