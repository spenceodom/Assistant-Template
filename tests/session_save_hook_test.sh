#!/usr/bin/env bash
# Tests for scripts/session-save-hook.sh
#
# Strategy:
#   - Build fake transcript JSONL files and fake hook-input JSON
#   - Run the hook with MEMORY_SAVE_STATE_DIR pointing at a tmp dir so tests
#     don't touch the real journal/ directory
#   - Assert on both stdout (the JSON decision) and the state file contents

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_DIR/scripts/session-save-hook.sh"

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'save-hook')"
STATE_DIR="$TMP_ROOT/state"
TRANSCRIPT="$TMP_ROOT/transcript.jsonl"
mkdir -p "$STATE_DIR"

trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
total=0

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  total=$((total + 1))
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL - $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

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

make_transcript() {
  # Args: number of user turns
  local n="$1"
  : > "$TRANSCRIPT"
  local i=1
  while [ "$i" -le "$n" ]; do
    printf '{"message":{"role":"user","content":"msg %d"}}\n' "$i" >> "$TRANSCRIPT"
    printf '{"message":{"role":"assistant","content":"resp %d"}}\n' "$i" >> "$TRANSCRIPT"
    i=$((i + 1))
  done
}

run_hook() {
  # Args: session_id, stop_hook_active (true|false), transcript_path, SAVE_INTERVAL
  local sid="$1" sha="$2" tp="$3" interval="$4"
  local input
  input=$(printf '{"session_id":"%s","stop_hook_active":%s,"transcript_path":"%s"}' \
    "$sid" "$sha" "$tp")
  MEMORY_SAVE_STATE_DIR="$STATE_DIR" MEMORY_SAVE_INTERVAL="$interval" \
    bash "$HOOK" <<<"$input"
}

# -----------------------------------------------------------------------------
# 1. stop_hook_active=true short-circuits (anti-loop guard)
# -----------------------------------------------------------------------------
make_transcript 50
out="$(run_hook "loop-test" true "$TRANSCRIPT" 2)"
assert_eq "stop_hook_active=true returns empty object" "{}" "$out"

# -----------------------------------------------------------------------------
# 2. Empty transcript path returns {} (no count, no save)
# -----------------------------------------------------------------------------
out="$(run_hook "empty-tp" false "" 2)"
assert_eq "missing transcript_path returns empty object" "{}" "$out"

# -----------------------------------------------------------------------------
# 3. Nonexistent transcript path returns {} (robust against stale references)
# -----------------------------------------------------------------------------
out="$(run_hook "missing-tp" false "$TMP_ROOT/does-not-exist.jsonl" 2)"
assert_eq "nonexistent transcript_path returns empty object" "{}" "$out"

# -----------------------------------------------------------------------------
# 4. Under-threshold: 3 user messages, interval 5 => no block
# -----------------------------------------------------------------------------
make_transcript 3
out="$(run_hook "under-threshold" false "$TRANSCRIPT" 5)"
assert_eq "under-threshold returns empty object" "{}" "$out"

[ -f "$STATE_DIR/.save_state_under-threshold" ] && \
  { echo "FAIL - under-threshold should not create state file"; FAIL=$((FAIL + 1)); } || \
  { echo "ok - under-threshold does not create state file"; PASS=$((PASS + 1)); }
total=$((total + 1))

# -----------------------------------------------------------------------------
# 5. At threshold: 5 messages, interval 5 => block, state file = 5
# -----------------------------------------------------------------------------
make_transcript 5
out="$(run_hook "at-threshold" false "$TRANSCRIPT" 5)"
assert_contains "at-threshold emits block decision" '"decision": "block"' "$out"
assert_contains "at-threshold mentions FORCED-SAVE" "FORCED-SAVE checkpoint" "$out"

state_content="$(cat "$STATE_DIR/.save_state_at-threshold" 2>/dev/null || echo MISSING)"
assert_eq "at-threshold writes checkpoint=5" "5" "$state_content"

# -----------------------------------------------------------------------------
# 6. After checkpoint advances, new messages below interval => no block
# -----------------------------------------------------------------------------
make_transcript 7  # +2 messages since last save (which was 5)
out="$(run_hook "at-threshold" false "$TRANSCRIPT" 5)"
assert_eq "post-save under-threshold returns empty object" "{}" "$out"

# Checkpoint should NOT have advanced
state_content="$(cat "$STATE_DIR/.save_state_at-threshold" 2>/dev/null || echo MISSING)"
assert_eq "post-save checkpoint stays at 5" "5" "$state_content"

# -----------------------------------------------------------------------------
# 7. Next checkpoint fires at 10 user messages (5 + 5 interval)
# -----------------------------------------------------------------------------
make_transcript 10
out="$(run_hook "at-threshold" false "$TRANSCRIPT" 5)"
assert_contains "second checkpoint emits block decision" '"decision": "block"' "$out"
state_content="$(cat "$STATE_DIR/.save_state_at-threshold" 2>/dev/null || echo MISSING)"
assert_eq "second checkpoint advances state to 10" "10" "$state_content"

# -----------------------------------------------------------------------------
# 8. Slash-command stubs (<command-message>) are NOT counted as user turns
# -----------------------------------------------------------------------------
: > "$TRANSCRIPT"
# 3 real user messages, 2 slash-command stubs — only 3 should count
printf '{"message":{"role":"user","content":"real 1"}}\n' >> "$TRANSCRIPT"
printf '{"message":{"role":"user","content":"<command-message>slash</command-message>"}}\n' >> "$TRANSCRIPT"
printf '{"message":{"role":"user","content":"real 2"}}\n' >> "$TRANSCRIPT"
printf '{"message":{"role":"user","content":"<command-message>again</command-message>"}}\n' >> "$TRANSCRIPT"
printf '{"message":{"role":"user","content":"real 3"}}\n' >> "$TRANSCRIPT"

out="$(run_hook "slash-filter" false "$TRANSCRIPT" 4)"
assert_eq "slash-command stubs don't count (3 real < 4 interval)" "{}" "$out"

out="$(run_hook "slash-filter" false "$TRANSCRIPT" 3)"
assert_contains "slash-command filtering: 3 real messages trigger at interval 3" '"decision": "block"' "$out"

# -----------------------------------------------------------------------------
# 9. Session isolation — different session_ids have independent state
# -----------------------------------------------------------------------------
make_transcript 5
out_a="$(run_hook "session-a" false "$TRANSCRIPT" 5)"
out_b="$(run_hook "session-b" false "$TRANSCRIPT" 5)"
assert_contains "session A fires block" '"decision": "block"' "$out_a"
assert_contains "session B fires block" '"decision": "block"' "$out_b"

# Advance session-a's checkpoint by 5 more, verify session-b's state is untouched
make_transcript 10
_=$(run_hook "session-a" false "$TRANSCRIPT" 5)
state_b="$(cat "$STATE_DIR/.save_state_session-b" 2>/dev/null)"
assert_eq "session B checkpoint unchanged by session A" "5" "$state_b"

# -----------------------------------------------------------------------------
# 10. Session ID sanitization — path traversal attempts stripped
# -----------------------------------------------------------------------------
make_transcript 5
# shellcheck disable=SC2016
out="$(run_hook '../../../etc/passwd' false "$TRANSCRIPT" 5)"
assert_contains "malicious session_id still fires block" '"decision": "block"' "$out"

# The state file should be written to the sanitized name, NOT outside STATE_DIR
if [ -f "$STATE_DIR/.save_state_etcpasswd" ]; then
  echo "ok - session_id sanitized (slashes and dots stripped)"
  PASS=$((PASS + 1))
else
  echo "FAIL - expected sanitized state file .save_state_etcpasswd"
  ls "$STATE_DIR" >&2
  FAIL=$((FAIL + 1))
fi
total=$((total + 1))

# No file should have been written outside the state dir
if [ -f "/etc/passwd.save_state" ] || [ -f "$TMP_ROOT/../etc/passwd" ]; then
  echo "FAIL - path traversal succeeded!"
  FAIL=$((FAIL + 1))
else
  echo "ok - no file written outside state dir"
  PASS=$((PASS + 1))
fi
total=$((total + 1))

# -----------------------------------------------------------------------------
# 11. Malformed hook input is handled gracefully
# -----------------------------------------------------------------------------
out="$(printf 'not valid json' | \
  MEMORY_SAVE_STATE_DIR="$STATE_DIR" MEMORY_SAVE_INTERVAL=5 \
  bash "$HOOK")"
assert_eq "malformed JSON input returns empty object" "{}" "$out"

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
