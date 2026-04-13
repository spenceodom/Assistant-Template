#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/memory_update.sh validate <target-file> --content <text>
  scripts/memory_update.sh add <target-file> --content <text>
  scripts/memory_update.sh replace <target-file> --match <text> --content <text>
  scripts/memory_update.sh remove <target-file> --match <text>

Notes:
  - Only files under self-improving/** are supported.
  - journal/** is out of scope for this tool.
  - Boundary and threat scans are best-effort lint, not a security boundary.
EOF
}

fail() {
  echo "memory_update: $*" >&2
  exit 1
}

is_exempt_from_provenance() {
  local target="$1"
  case "$(basename "$target")" in
    observations.md|corrections.md|profile.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

canonical_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -am "$path"
    return
  fi
  python - "$path" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve())
PY
}

SELF_IMPROVING_DIR="$(canonical_path "$PROJECT_DIR/self-improving")"
JOURNAL_DIR="$(canonical_path "$PROJECT_DIR/journal")"

ensure_target_allowed() {
  local raw_target="$1"
  local target
  target="$(canonical_path "$raw_target")"

  case "$target" in
    "$SELF_IMPROVING_DIR"/*) ;;
    *) fail "target must live under self-improving/**: $raw_target" ;;
  esac

  if [[ "$target" == "$JOURNAL_DIR" ]] || [[ "$target" == "$JOURNAL_DIR"/* ]]; then
    fail "journal/** is append-only and out of scope: $raw_target"
  fi

  if [[ ! -f "$target" ]]; then
    fail "target file does not exist: $raw_target"
  fi

  printf '%s\n' "$target"
}

lint_boundary_content() {
  local content="$1"

  if grep -Eqi -- '-----BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY-----' <<<"$content"; then
    fail "content looks like a private key"
  fi

  if grep -Eqi -- '\b(password|passwd|api[_ -]?key|secret|token)\b[[:space:]]*[:=][[:space:]]*\S+' <<<"$content"; then
    fail "content appears to include credential material"
  fi

  if grep -Eqi -- '\b(bearer|authorization)\b[[:space:]]+[A-Za-z0-9._~+/=-]{12,}' <<<"$content"; then
    fail "content appears to include an auth token"
  fi

  # ERE doesn't support PCRE (?:...) or \d. Use plain grouping + [0-9].
  # Matches 13-19 consecutive digits with optional space/dash separators
  # (covers most card and account formats).
  if grep -Eq -- '([0-9][ -]?){13,19}' <<<"$content"; then
    fail "content appears to include a card or account-like number"
  fi

  # ERE: use plain grouping, not PCRE (?:...).
  if grep -Eqi -- '\b(bc1|[13])[a-z0-9]{20,}\b' <<<"$content"; then
    fail "content appears to include a crypto wallet identifier"
  fi

  if grep -Eqi -- '(^|[^A-Za-z])(abandon|ability|able|about|above|absent|absorb|abstract|absurd|abuse|access|accident|account|accuse|achieve|acid|acoustic|acquire|across|act|action|actor|actress|actual|adapt|add|addict|address|adjust|admit|adult|advance|advice|aerobic|affair|afford|afraid|again|age|agent|agree|ahead|aim|air|airport|aisle|alarm|album|alcohol)( [a-z]{3,10}){11,}($|[^A-Za-z])' <<<"$content"; then
    fail "content appears to include a seed-phrase-like sequence"
  fi

  if grep -Eqi -- '\b[0-9]{1,6}[[:space:]]+[A-Za-z0-9.-]+[[:space:]]+(street|st|avenue|ave|road|rd|lane|ln|drive|dr|court|ct|boulevard|blvd)\b' <<<"$content"; then
    fail "content appears to include a detailed street address"
  fi
}

lint_threat_content() {
  local content="$1"

  if grep -Eqi -- '(ignore|override|bypass|forget)[[:space:]]+(all[[:space:]]+)?(previous|prior|earlier|system|developer)[[:space:]]+(instructions|prompts?)' <<<"$content"; then
    fail "content appears to contain prompt-injection language"
  fi

  if grep -Eqi -- '\b(exfiltrate|export all secrets|dump (the )?(full )?(memory|prompt|context)|reveal ([[:alnum:]_-]+[[:space:]]+){0,3}prompt)\b' <<<"$content"; then
    fail "content appears to contain exfiltration language"
  fi

  # Network exfil / remote exec patterns. The curl/wget branch accepts
  # flags (`-X`), URLs (`https://`, `foo://`), AND shell variable refs
  # (`$TOKEN`, `"$URL"`, `'$URL'`) so real exfil shapes are caught.
  if grep -Eqi -- '(\bInvoke-WebRequest\b|\b(curl|wget)\b[[:space:]]+(-[A-Za-z]|https?://|[[:alnum:]+.-]+://|["'\'']?\$)|\b(scp|ssh)\b[[:space:]]+(-[A-Za-z]|[[:alnum:]_.-]+@))' <<<"$content"; then
    fail "content appears to contain shell/network command language"
  fi

  # Invisible-unicode check. Bash $'...' does NOT expand \uXXXX on msys
  # bash, so constructing the byte pattern via printf is portable across
  # git-bash and Linux. Patterns: U+200B ZWSP, U+200C ZWNJ, U+200D ZWJ,
  # U+2060 WJ, U+FEFF BOM. Uses grep -F to avoid regex metacharacter issues.
  local _invisibles
  _invisibles="$(printf '\xe2\x80\x8b\n\xe2\x80\x8c\n\xe2\x80\x8d\n\xe2\x81\xa0\n\xef\xbb\xbf')"
  if printf '%s' "$content" | LC_ALL=C grep -Fq -- "$_invisibles"; then
    fail "content appears to contain invisible unicode control characters"
  fi
}

validate_provenance_shape() {
  local content="$1"
  local source_ref

  [[ "$content" == *" | source: "* ]] || fail "canonical add content must include ' | source: '"

  source_ref="${content##* | source: }"
  [[ "$source_ref" =~ ^(journal|observation|correction|user|legacy):[a-z0-9#.-]+$ ]] \
    || fail "source must match <type>:<ref> using lowercase slugs"

  if [[ "$source_ref" =~ ^legacy: ]] && [[ "$source_ref" != "legacy:pre-provenance" ]]; then
    fail "legacy provenance must be exactly legacy:pre-provenance"
  fi

  if [[ "$source_ref" =~ ^journal: ]] && [[ ! "$source_ref" =~ ^journal:[0-9]{4}-[0-9]{2}\.md#[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-[a-z0-9-]+$ ]]; then
    fail "journal provenance must match YYYY-MM.md#YYYY-MM-DD-HHMM-topic-slug"
  fi

  if [[ "$source_ref" =~ ^observation: ]] && [[ ! "$source_ref" =~ ^observation:[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+$ ]]; then
    fail "observation provenance must match YYYY-MM-DD-description-slug"
  fi

  if [[ "$source_ref" =~ ^correction: ]] && [[ ! "$source_ref" =~ ^correction:[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+$ ]]; then
    fail "correction provenance must match YYYY-MM-DD-topic-slug"
  fi

  # user refs are either `user:YYYY-MM-DD-slug` (dated) or `user:slug` (undated,
  # for things like `user:explicit-statement`). Both are valid per the spec.
  if [[ "$source_ref" =~ ^user: ]] && [[ ! "$source_ref" =~ ^user:([0-9]{4}-[0-9]{2}-[0-9]{2}-)?[a-z0-9-]+$ ]]; then
    fail "user provenance must match user:YYYY-MM-DD-slug or user:slug"
  fi
}

apply_list_shape() {
  local target="$1"
  local content="$2"
  local last_non_empty
  local prefix=""

  last_non_empty="$(python - "$target" <<'PY'
from pathlib import Path
import sys

for line in reversed(Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()):
    if line.strip():
        print(line)
        break
PY
)"

  if [[ "$last_non_empty" =~ ^[[:space:]]*-[[:space:]]+ ]]; then
    prefix="- "
  elif [[ "$last_non_empty" =~ ^[[:space:]]*\*[[:space:]]+ ]]; then
    prefix="* "
  fi

  if [[ -n "$prefix" ]] && [[ ! "$content" =~ ^[[:space:]]*[-*][[:space:]]+ ]]; then
    printf '%s%s\n' "$prefix" "$content"
  else
    printf '%s\n' "$content"
  fi
}

write_python_edit() {
  local mode="$1"
  local target="$2"
  local match="$3"
  local content="$4"

  python - "$mode" "$target" "$match" "$content" <<'PY'
from pathlib import Path
import sys

mode, target, match, content = sys.argv[1:5]
path = Path(target)
text = path.read_text(encoding="utf-8", errors="replace")
newline = "\r\n" if "\r\n" in text else "\n"

if mode == "add":
    if text and not text.endswith(("\n", "\r")):
        text += newline
    text += content + newline
    path.write_text(text, encoding="utf-8", newline="")
    raise SystemExit(0)

count = text.count(match)
if count == 0:
    raise SystemExit(3)
if count > 1:
    raise SystemExit(4)

if mode == "replace":
    text = text.replace(match, content, 1)
elif mode == "remove":
    text = text.replace(match, "", 1)
else:
    raise SystemExit(99)

path.write_text(text, encoding="utf-8", newline="")
PY
}

run_validate() {
  local target="$1"
  local content="$2"
  local resolved_target
  resolved_target="$(ensure_target_allowed "$target")"

  lint_boundary_content "$content"
  lint_threat_content "$content"

  printf 'validate ok: %s\n' "$resolved_target"
}

run_add() {
  local target="$1"
  local content="$2"
  local resolved_target
  local final_content

  resolved_target="$(ensure_target_allowed "$target")"
  final_content="$(apply_list_shape "$resolved_target" "$content")"

  lint_boundary_content "$final_content"
  lint_threat_content "$final_content"

  if ! is_exempt_from_provenance "$resolved_target"; then
    validate_provenance_shape "$final_content"
  fi

  write_python_edit "add" "$resolved_target" "" "$final_content"
  printf 'add ok: %s\n' "$resolved_target"
}

run_replace() {
  local target="$1"
  local match="$2"
  local content="$3"
  local resolved_target
  local status

  [[ -n "$match" ]] || fail "replace requires --match"
  [[ -n "$content" ]] || fail "replace requires --content"

  resolved_target="$(ensure_target_allowed "$target")"
  lint_boundary_content "$content"
  lint_threat_content "$content"

  if write_python_edit "replace" "$resolved_target" "$match" "$content" >/dev/null 2>&1; then
    printf 'replace ok: %s\n' "$resolved_target"
    return
  fi

  status=$?
  case "$status" in
    3) fail "replace requires exactly one match; found 0 matches" ;;
    4) fail "replace requires exactly one match; found multiple matches" ;;
    *) fail "replace failed unexpectedly" ;;
  esac
}

run_remove() {
  local target="$1"
  local match="$2"
  local resolved_target
  local status

  [[ -n "$match" ]] || fail "remove requires --match"
  resolved_target="$(ensure_target_allowed "$target")"

  if write_python_edit "remove" "$resolved_target" "$match" "" >/dev/null 2>&1; then
    printf 'remove ok: %s\n' "$resolved_target"
    return
  fi

  status=$?
  case "$status" in
    3) fail "remove requires exactly one match; found 0 matches" ;;
    4) fail "remove requires exactly one match; found multiple matches" ;;
    *) fail "remove failed unexpectedly" ;;
  esac
}

parse_args() {
  if [[ $# -lt 2 ]]; then
    usage
    exit 1
  fi

  COMMAND="$1"
  TARGET="$2"
  shift 2

  CONTENT=""
  MATCH=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --content)
        [[ $# -ge 2 ]] || fail "--content requires a value"
        CONTENT="$2"
        shift 2
        ;;
      --match)
        [[ $# -ge 2 ]] || fail "--match requires a value"
        MATCH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  case "$COMMAND" in
    validate)
      [[ -n "$CONTENT" ]] || fail "validate requires --content"
      run_validate "$TARGET" "$CONTENT"
      ;;
    add)
      [[ -n "$CONTENT" ]] || fail "add requires --content"
      run_add "$TARGET" "$CONTENT"
      ;;
    replace)
      run_replace "$TARGET" "$MATCH" "$CONTENT"
      ;;
    remove)
      run_remove "$TARGET" "$MATCH"
      ;;
    *)
      usage
      fail "unknown command: $COMMAND"
      ;;
  esac
}

main "$@"
