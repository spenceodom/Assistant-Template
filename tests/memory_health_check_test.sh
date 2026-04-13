#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$PROJECT_DIR/scripts/memory_health_check.sh"
TMP_DIR="$(mktemp -d "$PROJECT_DIR/self-improving/.memory-health-test.XXXXXX")"
CANONICAL_DIR="$TMP_DIR/self-improving"

mkdir -p "$CANONICAL_DIR/domains"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# Create test files
cat >"$CANONICAL_DIR/memory.md" <<'EOF'
# Memory
<!-- Provenance: all entries below predate the 2026-04-10 provenance scheme and are grandfathered as `legacy:pre-provenance`. New entries added via `scripts/memory_update.sh` must carry inline `| source: <type>:<ref>` stamps per `CLAUDE.md#Provenance`. -->

- Valid grandfathered entry.
- New entry with valid stamp. | source: user:2026-04-10-explicit-statement
- New entry with invalid stamp. | source: invalid:shape
- Missing stamp entry.
EOF

cat >"$CANONICAL_DIR/observations.md" <<'EOF'
# Observations
- [count:1] [first:2026-01-01] [last:2026-01-01] Stale observation
- [count:1] [first:2026-04-10] [last:2026-04-10] Fresh observation
EOF

cat >"$CANONICAL_DIR/profile.md" <<'EOF'
# Profile
- Exempt file entry.
EOF

# Run tool and capture output. The script reads CANONICAL_DIR from
# MEMORY_HEALTH_CANONICAL_DIR env var, so testing against a temp dir
# requires no script mutation. This replaces the earlier (dangerous)
# pattern of `sed -i`-ing the script and reverting via git checkout,
# which left the script broken on any mid-test kill.
#
# The test data is DESIGNED to trigger warnings (invalid provenance
# shape, stale observation) so the script is expected to exit 1.
# Capture the exit code separately and assert on it explicitly.
set +e
output=$(MEMORY_HEALTH_CANONICAL_DIR="$CANONICAL_DIR" bash "$TOOL")
tool_exit=$?
set -e

# Assertions
assert_contains() {
    local pattern="$1"
    local message="$2"
    if echo "$output" | grep -q "$pattern"; then
        echo "ok - $message"
    else
        echo "not ok - $message (pattern '$pattern' not found)"
        exit 1
    fi
}

echo "Testing memory_health_check.sh..."

assert_contains "memory.md" "Reports metrics for memory.md"
assert_contains "observations.md" "Reports metrics for observations.md"
assert_contains "profile.md" "Reports metrics for profile.md"

assert_contains "Total canonical lines: 4" "Counts canonical lines correctly"
assert_contains "Stamped or grandfathered: 4" "Counts stamped/grandfathered lines correctly (all 4 in this case)"

assert_contains "\[INVALID SHAPE\]" "Flags invalid provenance shape"
assert_contains "\[STALE\]" "Flags stale observations"
assert_contains "Total observations: 2" "Counts observations correctly"

# Exit code assertion: because the test data has warnings (invalid
# shape + stale observation), the script MUST exit 1. Exit 0 on this
# input would mean the warning signal is broken.
if [[ "$tool_exit" -eq 1 ]]; then
    echo "ok - script exits 1 when warnings are present"
else
    echo "not ok - expected exit 1 with warnings, got $tool_exit"
    exit 1
fi

# Clean-input exit code: run against a pristine grandfathered-only
# fixture and verify exit 0.
CLEAN_DIR="$TMP_DIR/clean/self-improving"
mkdir -p "$CLEAN_DIR/domains"
cat >"$CLEAN_DIR/memory.md" <<'EOF'
# Memory
<!-- Provenance: all entries below predate the 2026-04-10 provenance scheme and are grandfathered as `legacy:pre-provenance`. New entries added via `scripts/memory_update.sh` must carry inline `| source: <type>:<ref>` stamps per `CLAUDE.md#Provenance`. -->

- Grandfathered entry one.
- Grandfathered entry two.
EOF
cat >"$CLEAN_DIR/observations.md" <<EOF
# Observations
- [count:1] [first:$(date +%Y-%m-%d)] [last:$(date +%Y-%m-%d)] Fresh observation
EOF

set +e
MEMORY_HEALTH_CANONICAL_DIR="$CLEAN_DIR" bash "$TOOL" >/dev/null
clean_exit=$?
set -e

if [[ "$clean_exit" -eq 0 ]]; then
    echo "ok - script exits 0 on clean input"
else
    echo "not ok - expected exit 0 on clean input, got $clean_exit"
    exit 1
fi

# =============================================================================
# Contradiction scan tests
# =============================================================================

# A. Fixture with a clear contradiction: two lines sharing keywords about
#    "postgres database projects performance" but with opposing anchors
#    ("prefer" vs "avoid").
CONTRA_DIR="$TMP_DIR/contradict/self-improving"
mkdir -p "$CONTRA_DIR/domains"
cat >"$CONTRA_DIR/memory.md" <<'EOF'
# Memory
<!-- Provenance: all entries below predate the 2026-04-10 provenance scheme and are grandfathered as `legacy:pre-provenance`. New entries added via `scripts/memory_update.sh` must carry inline `| source: <type>:<ref>` stamps per `CLAUDE.md#Provenance`. -->

- Prefers postgres database technology for concurrent-write projects with performance constraints.
- Avoids postgres database technology when concurrent-write projects need performance.
EOF
cat >"$CONTRA_DIR/observations.md" <<EOF
# Observations
- [count:1] [first:$(date +%Y-%m-%d)] [last:$(date +%Y-%m-%d)] Fresh
EOF

set +e
contra_output=$(MEMORY_HEALTH_CANONICAL_DIR="$CONTRA_DIR" bash "$TOOL" 2>&1)
contra_exit=$?
set -e

if echo "$contra_output" | grep -q "\[CONTRADICTION-CANDIDATE\]"; then
    echo "ok - detects obvious contradiction candidate (opposing anchors + shared keywords)"
else
    echo "not ok - failed to detect contradiction candidate"
    echo "$contra_output"
    exit 1
fi

# B. Clean fixture — two lines about different topics should NOT be flagged.
NOCONTRA_DIR="$TMP_DIR/nocontra/self-improving"
mkdir -p "$NOCONTRA_DIR/domains"
cat >"$NOCONTRA_DIR/memory.md" <<'EOF'
# Memory
<!-- Provenance: all entries below predate the 2026-04-10 provenance scheme and are grandfathered as `legacy:pre-provenance`. New entries added via `scripts/memory_update.sh` must carry inline `| source: <type>:<ref>` stamps per `CLAUDE.md#Provenance`. -->

- Prefers concise direct communication without unnecessary filler words.
- Always never avoids writing detailed technical architecture documents when building complex systems.
EOF
cat >"$NOCONTRA_DIR/observations.md" <<EOF
# Observations
- [count:1] [first:$(date +%Y-%m-%d)] [last:$(date +%Y-%m-%d)] Fresh
EOF

set +e
nocontra_output=$(MEMORY_HEALTH_CANONICAL_DIR="$NOCONTRA_DIR" bash "$TOOL" 2>&1)
set -e

# The second line has BOTH a positive and negative anchor, so classify_anchors
# returns "both_or_neither" and it's skipped. The first has only "prefers".
# No pair can form. Expect either "No contradiction candidates found." OR
# no candidates at all against these inputs.
if echo "$nocontra_output" | grep -q "No contradiction candidates found."; then
    echo "ok - does not false-positive on unrelated topics"
else
    echo "not ok - unexpected contradiction flagged on clean fixture"
    echo "$nocontra_output"
    exit 1
fi

# C. Contradiction scan skips observations.md (scratchpad — contradictions
#    there are expected by design)
SKIP_DIR="$TMP_DIR/skip/self-improving"
mkdir -p "$SKIP_DIR/domains"
cat >"$SKIP_DIR/memory.md" <<'EOF'
# Memory
<!-- Provenance: all entries below predate the 2026-04-10 provenance scheme and are grandfathered as `legacy:pre-provenance`. New entries added via `scripts/memory_update.sh` must carry inline `| source: <type>:<ref>` stamps per `CLAUDE.md#Provenance`. -->

- Sample grandfathered entry about something benign.
EOF
# Put the contradiction in observations.md — should NOT be flagged
cat >"$SKIP_DIR/observations.md" <<EOF
# Observations
- [count:1] [first:$(date +%Y-%m-%d)] [last:$(date +%Y-%m-%d)] Prefers postgres database technology for concurrent write projects performance
- [count:1] [first:$(date +%Y-%m-%d)] [last:$(date +%Y-%m-%d)] Avoids postgres database technology when concurrent write projects need performance
EOF

set +e
skip_output=$(MEMORY_HEALTH_CANONICAL_DIR="$SKIP_DIR" bash "$TOOL" 2>&1)
set -e

if echo "$skip_output" | grep -q "\[CONTRADICTION-CANDIDATE\]"; then
    echo "not ok - contradiction scan should skip observations.md but flagged a candidate"
    echo "$skip_output"
    exit 1
else
    echo "ok - contradiction scan skips observations.md"
fi

# D. Threshold boundary: opposing anchors but only 2 shared keywords
#    (below MIN_SHARED_KEYWORDS = 3) should NOT trigger a candidate.
THRESH_DIR="$TMP_DIR/thresh/self-improving"
mkdir -p "$THRESH_DIR/domains"
cat >"$THRESH_DIR/memory.md" <<'EOF'
# Memory
<!-- Provenance: all entries below predate the 2026-04-10 provenance scheme and are grandfathered as `legacy:pre-provenance`. New entries added via `scripts/memory_update.sh` must carry inline `| source: <type>:<ref>` stamps per `CLAUDE.md#Provenance`. -->

- Prefers postgres database strictly because replication works reliably.
- Avoids postgres database completely because licensing creates friction.
EOF
cat >"$THRESH_DIR/observations.md" <<EOF
# Observations
- [count:1] [first:$(date +%Y-%m-%d)] [last:$(date +%Y-%m-%d)] Fresh
EOF

set +e
thresh_output=$(MEMORY_HEALTH_CANONICAL_DIR="$THRESH_DIR" bash "$TOOL" 2>&1)
set -e

if echo "$thresh_output" | grep -q "\[CONTRADICTION-CANDIDATE\]"; then
    echo "not ok - <3 shared keywords should not trigger a candidate"
    echo "$thresh_output"
    exit 1
else
    echo "ok - respects MIN_SHARED_KEYWORDS threshold"
fi

# E. Same-direction pair: two positive-anchor lines sharing many keywords
#    should NOT trigger a candidate (not opposing).
SAMEDIR_DIR="$TMP_DIR/samedir/self-improving"
mkdir -p "$SAMEDIR_DIR/domains"
cat >"$SAMEDIR_DIR/memory.md" <<'EOF'
# Memory
<!-- Provenance: all entries below predate the 2026-04-10 provenance scheme and are grandfathered as `legacy:pre-provenance`. New entries added via `scripts/memory_update.sh` must carry inline `| source: <type>:<ref>` stamps per `CLAUDE.md#Provenance`. -->

- Prefers postgres database technology for concurrent-write projects with performance constraints.
- Always chooses postgres database technology for concurrent-write projects needing performance.
EOF
cat >"$SAMEDIR_DIR/observations.md" <<EOF
# Observations
- [count:1] [first:$(date +%Y-%m-%d)] [last:$(date +%Y-%m-%d)] Fresh
EOF

set +e
samedir_output=$(MEMORY_HEALTH_CANONICAL_DIR="$SAMEDIR_DIR" bash "$TOOL" 2>&1)
set -e

if echo "$samedir_output" | grep -q "\[CONTRADICTION-CANDIDATE\]"; then
    echo "not ok - same-direction pair should not trigger a candidate"
    echo "$samedir_output"
    exit 1
else
    echo "ok - same-direction pair is not flagged"
fi

echo "All tests passed!"
