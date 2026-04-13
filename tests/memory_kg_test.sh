#!/usr/bin/env bash
# Tests for scripts/memory_kg.sh
#
# All tests run against a tmp database (MEMORY_KG_DB) so the real
# self-improving/kg.sqlite is never touched.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KG="$PROJECT_DIR/scripts/memory_kg.sh"

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'kg-test')"
DB="$TMP_ROOT/test.sqlite"

trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
total=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
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
  local desc="$1" needle="$2" haystack="$3"
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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  total=$((total + 1))
  case "$haystack" in
    *"$needle"*)
      echo "FAIL - $desc"
      echo "  did NOT expect: $needle"
      echo "  actual:         $haystack"
      FAIL=$((FAIL + 1))
      ;;
    *)
      echo "ok - $desc"
      PASS=$((PASS + 1))
      ;;
  esac
}

assert_exit() {
  local desc="$1" expected_exit="$2" actual_exit="$3"
  total=$((total + 1))
  if [ "$expected_exit" = "$actual_exit" ]; then
    echo "ok - $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL - $desc (expected exit $expected_exit, got $actual_exit)"
    FAIL=$((FAIL + 1))
  fi
}

run_kg() {
  MEMORY_KG_DB="$DB" bash "$KG" "$@"
}

# -----------------------------------------------------------------------------
# 1. init creates the database
# -----------------------------------------------------------------------------
out="$(run_kg init 2>&1)"
exit_code=$?
assert_exit "init exits 0" 0 "$exit_code"
assert_contains "init reports ok" "init ok" "$out"
total=$((total + 1))
if [ -f "$DB" ]; then
  echo "ok - init creates db file"
  PASS=$((PASS + 1))
else
  echo "FAIL - init did not create db file"
  FAIL=$((FAIL + 1))
fi

# -----------------------------------------------------------------------------
# 2. add a basic triple
# -----------------------------------------------------------------------------
out="$(run_kg add "Kai" "works_on" "Orion" \
  --valid-from "2025-06-01" \
  --source "user:2025-06-01-explicit-statement" 2>&1)"
exit_code=$?
assert_exit "basic add exits 0" 0 "$exit_code"
assert_contains "basic add reports ok" "add ok" "$out"

# -----------------------------------------------------------------------------
# 3. add with invalid provenance shape
# -----------------------------------------------------------------------------
out="$(run_kg add "Kai" "likes" "coffee" \
  --valid-from "2025-06-01" \
  --source "bogus:not-a-real-type" 2>&1)"
exit_code=$?
assert_exit "invalid source type fails" 1 "$exit_code"
assert_contains "invalid source mentions type" "<type>:<ref>" "$out"

# -----------------------------------------------------------------------------
# 4. add with invalid date format
# -----------------------------------------------------------------------------
out="$(run_kg add "Kai" "likes" "coffee" \
  --valid-from "June 1, 2025" \
  --source "user:explicit-statement" 2>&1)"
exit_code=$?
assert_exit "invalid date fails" 1 "$exit_code"
assert_contains "invalid date mentions YYYY-MM-DD" "YYYY-MM-DD" "$out"

# -----------------------------------------------------------------------------
# 5. add with bad observation slug
# -----------------------------------------------------------------------------
out="$(run_kg add "Kai" "likes" "coffee" \
  --valid-from "2025-06-01" \
  --source "observation:no-date-here" 2>&1)"
exit_code=$?
assert_exit "malformed observation slug fails" 1 "$exit_code"
assert_contains "rejects observation shape" "observation:YYYY-MM-DD-description-slug" "$out"

# -----------------------------------------------------------------------------
# 6. add accepts valid observation slug
# -----------------------------------------------------------------------------
out="$(run_kg add "Kai" "prefers" "Postgres" \
  --valid-from "2025-07-01" \
  --source "observation:2025-07-01-chose-postgres-over-sqlite" 2>&1)"
exit_code=$?
assert_exit "valid observation source accepted" 0 "$exit_code"

# -----------------------------------------------------------------------------
# 7. add accepts valid journal source
# -----------------------------------------------------------------------------
out="$(run_kg add "Maya" "assigned_to" "auth-migration" \
  --valid-from "2026-01-15" \
  --source "journal:2026-01.md#2026-01-15-1430-auth-migration-assigned" 2>&1)"
exit_code=$?
assert_exit "valid journal source accepted" 0 "$exit_code"

# -----------------------------------------------------------------------------
# 8. add rejects legacy:anything-but-pre-provenance
# -----------------------------------------------------------------------------
out="$(run_kg add "Old" "fact" "Thing" \
  --valid-from "2020-01-01" \
  --source "legacy:made-up-slug" 2>&1)"
exit_code=$?
assert_exit "legacy with non-pre-provenance ref fails" 1 "$exit_code"

# -----------------------------------------------------------------------------
# 9. add rejects duplicate (same S+P+O+valid_from)
# -----------------------------------------------------------------------------
out="$(run_kg add "Kai" "works_on" "Orion" \
  --valid-from "2025-06-01" \
  --source "user:2025-06-01-explicit-statement" 2>&1)"
exit_code=$?
assert_exit "duplicate triple fails" 1 "$exit_code"
assert_contains "duplicate mentions invalidate" "invalidate" "$out"

# -----------------------------------------------------------------------------
# 10. query by entity (outgoing)
# -----------------------------------------------------------------------------
out="$(run_kg query "Kai" --direction outgoing 2>&1)"
assert_contains "query finds Kai->works_on->Orion" "Kai -> works_on -> Orion" "$out"
assert_contains "query finds Kai->prefers->Postgres" "Kai -> prefers -> Postgres" "$out"
assert_contains "query shows (current) for active" "(current)" "$out"

# -----------------------------------------------------------------------------
# 11. query by entity (incoming — Orion appears as object)
# -----------------------------------------------------------------------------
out="$(run_kg query "Orion" --direction incoming 2>&1)"
assert_contains "incoming query finds Kai->works_on->Orion" "Kai -> works_on -> Orion" "$out"

# -----------------------------------------------------------------------------
# 12. invalidate an active triple
# -----------------------------------------------------------------------------
out="$(run_kg invalidate "Kai" "works_on" "Orion" --ended "2026-03-01" 2>&1)"
exit_code=$?
assert_exit "invalidate exits 0" 0 "$exit_code"
assert_contains "invalidate reports ok" "invalidate ok" "$out"

# -----------------------------------------------------------------------------
# 13. after invalidate, query shows ended
# -----------------------------------------------------------------------------
out="$(run_kg query "Kai" --direction outgoing 2>&1)"
assert_contains "post-invalidate query shows ended" "(ended 2026-03-01)" "$out"

# -----------------------------------------------------------------------------
# 14. invalidate fails on nonexistent triple
# -----------------------------------------------------------------------------
out="$(run_kg invalidate "Nobody" "does" "Nothing" 2>&1)"
exit_code=$?
assert_exit "invalidate nonexistent fails" 1 "$exit_code"
assert_contains "nonexistent invalidate mentions no match" "no active triple" "$out"

# -----------------------------------------------------------------------------
# 15. invalidate fails on already-ended triple (no active match)
# -----------------------------------------------------------------------------
out="$(run_kg invalidate "Kai" "works_on" "Orion" 2>&1)"
exit_code=$?
assert_exit "re-invalidate of ended triple fails" 1 "$exit_code"

# -----------------------------------------------------------------------------
# 16. time-scoped query: as-of 2025-08-01, Kai works_on Orion was active
# -----------------------------------------------------------------------------
out="$(run_kg query "Kai" --as-of "2025-08-01" --direction outgoing 2>&1)"
assert_contains "as-of before end date includes the fact" "Kai -> works_on -> Orion" "$out"

# -----------------------------------------------------------------------------
# 17. time-scoped query: as-of 2026-04-01 (after ended), Kai no longer works on Orion
# -----------------------------------------------------------------------------
out="$(run_kg query "Kai" --as-of "2026-04-01" --direction outgoing 2>&1)"
assert_not_contains "as-of after end date excludes Orion" "Kai -> works_on -> Orion" "$out"
assert_contains "as-of after end still shows Postgres preference" "Kai -> prefers -> Postgres" "$out"

# -----------------------------------------------------------------------------
# 18. time-scoped query: as-of before valid_from excludes the fact
# -----------------------------------------------------------------------------
out="$(run_kg query "Kai" --as-of "2024-01-01" --direction outgoing 2>&1)"
assert_contains "as-of before any fact returns no triples" "(no triples for Kai)" "$out"

# -----------------------------------------------------------------------------
# 19. timeline chronological
# -----------------------------------------------------------------------------
out="$(run_kg timeline "Kai" 2>&1)"
assert_contains "timeline has header" "Timeline for Kai" "$out"
assert_contains "timeline includes Orion ended" "(ended 2026-03-01)" "$out"
assert_contains "timeline includes Postgres current" "Kai -> prefers -> Postgres" "$out"

# -----------------------------------------------------------------------------
# 20. stats summary
# -----------------------------------------------------------------------------
out="$(run_kg stats 2>&1)"
assert_contains "stats shows total" "Total triples:" "$out"
assert_contains "stats shows active" "active:" "$out"
assert_contains "stats shows ended" "ended:" "$out"

# -----------------------------------------------------------------------------
# 21. list dumps all triples
# -----------------------------------------------------------------------------
out="$(run_kg list 2>&1)"
assert_contains "list shows Kai works_on Orion" "Kai -> works_on -> Orion" "$out"
assert_contains "list shows Maya assigned_to auth" "Maya -> assigned_to -> auth-migration" "$out"

# -----------------------------------------------------------------------------
# 22. Re-add with a NEW valid_from is allowed (re-hire scenario)
# -----------------------------------------------------------------------------
out="$(run_kg add "Kai" "works_on" "Orion" \
  --valid-from "2026-05-01" \
  --source "user:2026-05-01-returned" 2>&1)"
exit_code=$?
assert_exit "re-add with new valid_from succeeds" 0 "$exit_code"

# Now query should show both (the ended one and the new current one)
out="$(run_kg query "Kai" --direction outgoing 2>&1)"
assert_contains "query shows original ended fact" "(ended 2026-03-01)" "$out"
# Find the "current" version of Kai->works_on->Orion (post 2026-05-01)
total=$((total + 1))
current_count="$(printf '%s' "$out" | grep -c 'Kai -> works_on -> Orion' || true)"
if [ "$current_count" = "2" ]; then
  echo "ok - query shows both historical and current works_on"
  PASS=$((PASS + 1))
else
  echo "FAIL - expected 2 works_on entries, got $current_count"
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
