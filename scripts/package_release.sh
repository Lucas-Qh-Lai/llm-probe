#!/usr/bin/env bash
# Builds the shippable macOS artefact: dist/LLMProbe-<version>.zip + its SHA-256.
#
# Usage: scripts/package_release.sh [version]
#
# The app bundle is assembled outside the checkout (scripts/build_app.sh) because
# a cloud-synced folder re-adds Finder metadata and breaks the ad-hoc signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Single source of truth for the version: LLMProbeVersion.short.
DEFAULT_VERSION="$(sed -nE 's/.*public static let short = "([^"]+)".*/\1/p' \
  Sources/LLMProbeCore/Providers/EndpointResolver.swift | head -1)"
VERSION="${1:-${DEFAULT_VERSION:-0.0.0}}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/llmprobe-package.XXXXXX")"
cleanup() { [ -d "$STAGE" ] && find "$STAGE" -depth -delete; }
trap cleanup EXIT

echo "==> Building the app for version $VERSION"
"$ROOT/scripts/build_app.sh" release "$STAGE"

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/LLMProbe-$VERSION.zip"
[ -e "$ZIP" ] && find "$ZIP" -delete
[ -e "$ZIP.sha256" ] && find "$ZIP.sha256" -delete

echo "==> Zipping $ZIP"
# `--sequesterRsrc` keeps extended attributes out of the archive so the ad-hoc
# signature survives the download/unzip round trip.
ditto -c -k --sequesterRsrc --keepParent "$STAGE/LLMProbe.app" "$ZIP"

echo "==> Checksums"
( cd "$ROOT/dist" && shasum -a 256 "LLMProbe-$VERSION.zip" | tee "LLMProbe-$VERSION.zip.sha256" )

echo "==> Done: $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
