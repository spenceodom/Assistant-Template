#!/usr/bin/env bash
# Tests for scripts/session-precompact-hook.sh
#
# The PreCompact hook is simple: always returns a block decision with a
# thorough save reason, regardless of input. Tests verify that contract.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_DIR/scripts/session-precompact-hook.sh"

PASS=0
FAIL=0
total=0

assert_contains() {
  local desc="$1"
  local needle="$2"
  local haystack="$3"
  total=$((total + 1))
  case "$haystack" in
    *"$needle"*)
      echo "ok - $desc"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "FAIL - $desc"
      echo "  expected to contain: $needle"
      echo "  actual:              $haystack"
      FAIL=$((FAIL + 1))
      ;;
  esac
}

assert_exit_zero() {
  local desc="$1"
  local actual="$2"
  total=$((total + 1))
  if [ "$actual" = "0" ]; then
    echo "ok - $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL - $desc (exit=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

# -----------------------------------------------------------------------------
# 1. Normal input: always blocks
# -----------------------------------------------------------------------------
out="$(bash "$HOOK" <<<'{"session_id":"test-session"}')"
exit_code=$?
assert_contains "normal input returns block decision" '"decision": "block"' "$out"
assert_contains "block reason mentions COMPACTION" 'COMPACTION IMMINENT' "$out"
assert_contains "reason mentions buffer flush" 'journal/buffer' "$out"
assert_contains "reason mentions memory_update.sh" 'memory_update.sh' "$out"
assert_exit_zero "normal input exits 0" "$exit_code"

# -----------------------------------------------------------------------------
# 2. Empty stdin: still blocks (PreCompact hook is unconditional)
# -----------------------------------------------------------------------------
out="$(bash "$HOOK" </dev/null)"
exit_code=$?
assert_contains "empty stdin still blocks" '"decision": "block"' "$out"
assert_exit_zero "empty stdin exits 0" "$exit_code"

# -----------------------------------------------------------------------------
# 3. Malformed JSON: still blocks (PreCompact doesn't parse fields)
# -----------------------------------------------------------------------------
out="$(bash "$HOOK" <<<'not valid json at all')"
exit_code=$?
assert_contains "malformed JSON still blocks" '"decision": "block"' "$out"
assert_exit_zero "malformed JSON exits 0" "$exit_code"

# -----------------------------------------------------------------------------
# 4. Large input doesn't hang or crash the hook
# -----------------------------------------------------------------------------
LARGE_INPUT="$(printf '{"session_id":"%s"}' "$(printf 'x%.0s' $(seq 1 1000))")"
out="$(bash "$HOOK" <<<"$LARGE_INPUT")"
exit_code=$?
assert_contains "large input still blocks" '"decision": "block"' "$out"
assert_exit_zero "large input exits 0" "$exit_code"

# -----------------------------------------------------------------------------
# 5. Output is valid JSON (can be parsed by python)
# -----------------------------------------------------------------------------
out="$(bash "$HOOK" <<<'{}')"
total=$((total + 1))
if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "ok - output parses as valid JSON"
  PASS=$((PASS + 1))
else
  echo "FAIL - output is not valid JSON: $out"
  FAIL=$((FAIL + 1))
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "1..$total"
echo "Passed: $PASS / $total"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAIL"
  exit 1
fi
echo "All tests passed!"
