#!/usr/bin/env bash
# Fails when a credential, a machine specific path or a captured profile looks
# like it is about to be committed.
#
# LLMProbe reads other agents' configuration files, so its development machine
# is full of real base URLs, model ids and API keys. This script is the last
# gate before `git commit` / `git push`.
#
# Usage:
#   scripts/check_privacy.sh            # scan files tracked by git (or the tree)
#   scripts/check_privacy.sh --staged   # scan only what is staged
#
# Exit codes: 0 clean · 1 findings · 2 environment problem
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# `mktemp -t NAME` is BSD-only: GNU mktemp requires the X's in the template, so
# the portable form keeps this script usable in the Linux CI job as well.
HIT_FILE="$(mktemp "${TMPDIR:-/tmp}/llmprobe-privacy-hit.XXXXXX")"

MODE="tree"
if [ "${1:-}" = "--staged" ]; then MODE="staged"; fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 2
fi

collect_files() {
  if [ "$MODE" = "staged" ]; then
    git diff --cached --name-only --diff-filter=ACMR 2>/dev/null
    return
  fi
  if git rev-parse --git-dir >/dev/null 2>&1; then
    # Tracked files plus anything untracked that is not ignored.
    git ls-files
    git ls-files --others --exclude-standard
  else
    find . -type f -not -path './.git/*' -not -path './.build/*' | sed 's|^\./||'
  fi
}

FILES="$(collect_files | sort -u | while read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done)"

findings=0
report() {
  findings=$((findings + 1))
  printf 'PRIVACY  %s:%s\n         %s\n' "$1" "$2" "$3"
}

# 1. Security tokens and API keys.
SECRET_PATTERNS=(
  'sk-[A-Za-z0-9_-]{16,}'
  'sk-ant-[A-Za-z0-9_-]{16,}'
  'gho_[A-Za-z0-9]{20,}'
  'ghp_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'AIza[0-9A-Za-z_-]{30,}'
  'ya29\.[0-9A-Za-z._-]{20,}'
  'hf_[A-Za-z0-9]{30,}'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

# 2. Credentials written into configuration snippets or source code. A quoted
#    literal is required, so ordinary code such as `secret = resolve(...)` does
#    not trip the check.
ASSIGNMENT_PATTERN='(api[_-]?key|apikey|auth[_-]?token|access[_-]?token|secret|password)["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][A-Za-z0-9_./+-]{20,}["'\'']'

# 3. Machine specific paths and identities.
MACHINE_PATTERNS=(
  "/Users/${USER:-__no_such_user__}/"
  "${HOME:-__no_such_home__}"
)

is_text() {
  # `file` is present on macOS and on every Linux CI image we target.
  case "$(file -b --mime-encoding "$1" 2>/dev/null)" in
    binary) return 1 ;;
    *) return 0 ;;
  esac
}

for file in $FILES; do
  case "$file" in
    # The self check and this script necessarily contain fake credentials.
    Sources/LLMProbeCore/Support/Redactor.swift|Sources/LLMProbeCore/Support/SelfTest.swift|scripts/check_privacy.sh) skip_secrets=1 ;;
    *) skip_secrets=0 ;;
  esac

  if is_text "$file"; then
    if [ "$skip_secrets" -eq 0 ]; then
      for pattern in "${SECRET_PATTERNS[@]}"; do
        if grep -nIE -- "$pattern" "$file" >"$HIT_FILE" 2>/dev/null; then
          report "$file" "$(head -1 "$HIT_FILE" | cut -d: -f1)" "possible credential matching /$pattern/"
        fi
      done
      if grep -nIE -- "$ASSIGNMENT_PATTERN" "$file" >"$HIT_FILE" 2>/dev/null; then
        report "$file" "$(head -1 "$HIT_FILE" | cut -d: -f1)" "credential-looking assignment: $(head -1 "$HIT_FILE" | cut -d: -f2- | cut -c1-90)"
      fi
    fi
  fi

  for pattern in "${MACHINE_PATTERNS[@]}"; do
    [ -z "$pattern" ] && continue
    if grep -aqF -- "$pattern" "$file" 2>/dev/null; then
      # Documentation is allowed to talk about ~/Library, not about a real user.
      case "$file" in
        README.md|README.en.md|CHANGELOG.md) continue ;;
      esac
      report "$file" "-" "contains this machine's path/identity: $pattern"
    fi
  done
done

# 4. Artefacts that must never be committed.
for forbidden in state.json; do
  if printf '%s\n' "$FILES" | grep -qx "$forbidden"; then
    report "$forbidden" "-" "local state must never be committed"
  fi
done
if printf '%s\n' "$FILES" | grep -qE '(^|/)LLMProbe\.app/'; then
  report "LLMProbe.app/" "-" "built app bundles must not be committed"
fi

# 5. Screenshots must come from the fictional demo pipeline.
for image in $(printf '%s\n' "$FILES" | grep -E '^docs/images/.*\.(png|jpg|jpeg)$'); do
  if command -v python3 >/dev/null 2>&1; then
    # A hit here is a finding, not a note: the repository promises screenshots
    # carry no capture metadata. `strip_image_metadata.py` removes it.
    metadata_state="$(python3 - "$image" <<'PY'
import struct, sys, zlib
path = sys.argv[1]
data = open(path, "rb").read()
if not data.startswith(b"\x89PNG\r\n\x1a\n"):
    sys.exit(0)
pos = 8
bad = []
while pos + 8 <= len(data):
    length = struct.unpack(">I", data[pos:pos + 4])[0]
    kind = data[pos + 4:pos + 8]
    payload = data[pos + 8:pos + 8 + length]
    if kind in (b"eXIf", b"iTXt", b"zTXt", b"tEXt"):
        text = payload.decode("latin-1", "replace")
        if any(marker in text for marker in ("UserComment", "Author", "Copyright", "Software", "Source")):
            bad.append(f"{kind.decode()} chunk with metadata: {text[:80]}")
    if kind == b"IEND":
        break
    pos += 12 + length
if bad:
    print("carries capture metadata: " + "; ".join(bad))
PY
)"
    if [ -n "$metadata_state" ]; then
      report "$image" "-" "$metadata_state"
    fi
  fi
done



[ -e "$HIT_FILE" ] && find "$HIT_FILE" -delete

if [ "$findings" -gt 0 ]; then
  printf '\n%d privacy finding(s) in %s mode. Fix them before committing.\n' "$findings" "$MODE" >&2
  exit 1
fi

count="$(printf '%s\n' "$FILES" | grep -c . || true)"
printf 'privacy check clean (%s files, mode=%s)\n' "$count" "$MODE"
