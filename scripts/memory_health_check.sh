#!/usr/bin/env bash

# memory_health_check.sh - Measurement-first health report for Phase 2.
# 
# Reports on:
# - Character counts by canonical file
# - Provenance coverage and shape validity
# - Stale observations and backlog
# - Contradiction candidates and duplicates
# - Bypass detection (commits missing memory_update.sh references)
# - Visible maintenance canary (neglected files, low coverage)

set -euo pipefail

# Configuration
# CANONICAL_DIR can be overridden via env var for testing. Default is the
# real self-improving tree.
CANONICAL_DIR="${MEMORY_HEALTH_CANONICAL_DIR:-self-improving}"
SCRIPTS_DIR="scripts"
MEMORY_UPDATE_SCRIPT="${SCRIPTS_DIR}/memory_update.sh"
STALE_THRESHOLD_DAYS=30
# The provenance scheme was adopted on 2026-04-10. Bypass detection
# only looks at commits on or after this date — earlier commits predate
# the wrapper and flagging them is meaningless noise.
PROVENANCE_SPEC_DATE="2026-04-10"

# Exit status tracking. 0 = clean, 1 = warnings.
EXIT_STATUS=0
warn() { EXIT_STATUS=1; }

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper to print headers
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# 1. Baseline Metrics: Character counts and file inventory
print_header "Baseline Metrics"
printf "%-40s %-10s %-10s\n" "File" "Chars" "Lines"
echo "----------------------------------------------------------------------"

TOTAL_CHARS=0
TOTAL_LINES=0

# Find all .md files in self-improving, excluding archive and docs (unless specified)
FILES=$(find "$CANONICAL_DIR" -name "*.md" -not -path "$CANONICAL_DIR/archive/*" -not -path "$CANONICAL_DIR/docs/*")

for file in $FILES; do
    chars=$(wc -c < "$file" | xargs)
    lines=$(wc -l < "$file" | xargs)
    printf "%-40s %-10s %-10s\n" "$file" "$chars" "$lines"
    TOTAL_CHARS=$((TOTAL_CHARS + chars))
    TOTAL_LINES=$((TOTAL_LINES + lines))
done

echo "----------------------------------------------------------------------"
printf "%-40s %-10s %-10s\n" "TOTAL" "$TOTAL_CHARS" "$TOTAL_LINES"


# 2. Provenance Coverage & Validity
print_header "Provenance Coverage"

# Excluded from provenance requirement per CLAUDE.md
EXEMPT_FILES=(
    "$CANONICAL_DIR/observations.md"
    "$CANONICAL_DIR/corrections.md"
    "$CANONICAL_DIR/profile.md"
    "$CANONICAL_DIR/reflections.md"
)

TOTAL_CANONICAL_LINES=0
STAMPED_LINES=0
GRANDFATHERED_FILES=0
INVALID_STAMPS=0

GRANDFATHER_PATTERN="grandfathered as \`legacy:pre-provenance\`"
PROVENANCE_STAMP_PATTERN=" \| source: "
VALID_TYPE_PATTERN='^(journal|observation|correction|user|legacy):[a-z0-9#.\-]+$'

for file in $FILES; do
    # Skip exempt files
    is_exempt=false
    for exempt in "${EXEMPT_FILES[@]}"; do
        if [[ "$file" == "$exempt" ]]; then
            is_exempt=true
            break
        fi
    done
    [[ "$is_exempt" == "true" ]] && continue

    has_grandfather=false
    if head -n 5 "$file" | grep -q "$GRANDFATHER_PATTERN"; then
        has_grandfather=true
        GRANDFATHERED_FILES=$((GRANDFATHERED_FILES + 1))
    fi

    # Read lines (excluding headers and empty lines)
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# || "$line" =~ ^\<!-- ]] && continue
        TOTAL_CANONICAL_LINES=$((TOTAL_CANONICAL_LINES + 1))

        if echo "$line" | grep -qF " | source: "; then
            STAMPED_LINES=$((STAMPED_LINES + 1))
            # Validate shape
            stamp=$(echo "$line" | sed 's/.* | source: //')
            if [[ ! "$stamp" =~ $VALID_TYPE_PATTERN ]]; then
                echo -e "${RED}[INVALID SHAPE]${NC} $file: $line"
                INVALID_STAMPS=$((INVALID_STAMPS + 1))
                warn
            fi
        elif [[ "$has_grandfather" == "true" ]]; then
            STAMPED_LINES=$((STAMPED_LINES + 1))
        else
            # Unstamped and not grandfathered
            echo -e "${YELLOW}[MISSING STAMP]${NC} $file: $line"
        fi
    done < "$file"
done

if [[ $TOTAL_CANONICAL_LINES -gt 0 ]]; then
    COVERAGE_PCT=$(( 100 * STAMPED_LINES / TOTAL_CANONICAL_LINES ))
    echo -e "Total canonical lines: $TOTAL_CANONICAL_LINES"
    echo -e "Stamped or grandfathered: $STAMPED_LINES ($COVERAGE_PCT%)"
    echo -e "Grandfathered files: $GRANDFATHERED_FILES"
    if [[ $INVALID_STAMPS -gt 0 ]]; then
        echo -e "${RED}Invalid provenance shapes: $INVALID_STAMPS${NC}"
    fi
else
    echo "No canonical lines found for provenance check."
fi


# 3. Observation Health
print_header "Observation Health"

OBS_FILE="$CANONICAL_DIR/observations.md"
if [[ -f "$OBS_FILE" ]]; then
    STALE_OBS=0
    TOTAL_OBS=0
    CURRENT_DATE=$(date +%Y-%m-%d)
    
    # Simple check for stale entries using bash
    while IFS= read -r line; do
        [[ ! "$line" =~ ^- ]] && continue
        TOTAL_OBS=$((TOTAL_OBS + 1))
        
        # Extract last: date
        if [[ "$line" =~ last:([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
            last_date="${BASH_REMATCH[1]}"
            # Calculate diff in days (approximate for measurement)
            if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
                # Windows git-bash date
                diff_secs=$(($(date -d "$CURRENT_DATE" +%s) - $(date -d "$last_date" +%s)))
            else
                # Linux/macOS
                diff_secs=$(($(date -d "$CURRENT_DATE" +%s) - $(date -d "$last_date" +%s)))
            fi
            diff_days=$((diff_secs / 86400))
            
            if [[ $diff_days -ge $STALE_THRESHOLD_DAYS ]]; then
                echo -e "${YELLOW}[STALE]${NC} ($diff_days days): $line"
                STALE_OBS=$((STALE_OBS + 1))
                warn
            fi
        fi
    done < "$OBS_FILE"
    
    echo -e "Total observations: $TOTAL_OBS"
    echo -e "Stale observations: $STALE_OBS"
else
    echo "observations.md not found."
fi


# 4. Duplicate & Contradiction Detection
print_header "Potential Conflicts & Duplicates"

# 4a. Simple duplicate line detection across all files
grep -h "^-" $FILES | sort | uniq -d | while read -r line; do
    echo -e "${YELLOW}[DUPLICATE]${NC} $line"
done

# 4b. Heuristic contradiction candidate scan.
# Scans canonical preference files for pairs of lines that:
#   - share >=3 significant keywords (alphanumeric, len>=4, not stopwords)
#   - contain OPPOSING anchor words (one positive, one negative)
# Emits candidates as informational output. False positives are expected
# and intentional — these are candidates for human review, not assertions.
# Skips observations.md (scratchpad), corrections.md (expected to override
# old behavior), and reflections.md (personal, not canonical claims).
#
# This implements Phase 3's "contradiction detection" in its minimal
# heuristic form per the plan: "Do not attempt LLM-based contradiction
# detection first. Try the heuristic version and see whether it's enough."
SCAN_FILES=()
for file in $FILES; do
    case "$(basename "$file")" in
        observations.md|corrections.md|reflections.md) continue ;;
    esac
    SCAN_FILES+=("$file")
done

if [ "${#SCAN_FILES[@]}" -gt 0 ]; then
    python3 - "${SCAN_FILES[@]}" <<'PY'
import re
import sys

# Common English stopwords + domain-specific noise words that dominate
# self-improving markdown without carrying semantic weight. Kept as a
# tuning knob — if candidate pairs start matching on a noise word, add
# it here. WORD_RE already excludes tokens shorter than 4 chars, so no
# need to list "the"-class words that fail that filter.
STOPWORDS = {
    "the", "and", "for", "with", "this", "that", "but", "not", "are", "was",
    "has", "have", "been", "will", "when", "what", "from", "into", "over",
    "your", "you", "user", "my", "our", "they", "them", "his",
    "her", "him", "she", "one", "two", "all", "any", "some", "out",
    "new", "old", "also", "which", "just", "than", "then", "because", "about",
    "after", "before", "there", "their", "these", "those", "very", "most",
    "such", "through", "under", "same", "other", "each",
    "many", "more", "much", "while", "only", "here", "where", "would",
    "should", "could", "must", "says", "said", "make", "makes", "made",
}

# Anchor words that mark a preference direction. A line with a POSITIVE
# anchor and another line with a NEGATIVE anchor sharing enough keywords
# is a contradiction candidate.
POSITIVE_ANCHORS = {
    "prefer", "prefers", "preferred", "always", "likes", "love", "loves",
    "want", "wants", "enjoys", "enjoy", "picks", "chooses", "chose",
}
NEGATIVE_ANCHORS = {
    "never", "dislike", "dislikes", "hate", "hates", "avoid", "avoids",
    "avoiding", "refuses", "refused", "stops", "stopped",
}

MIN_SHARED_KEYWORDS = 3

WORD_RE = re.compile(r"[a-z]{4,}")


def tokenize(line: str) -> set:
    words = WORD_RE.findall(line.lower())
    return {w for w in words if w not in STOPWORDS}


def classify_anchors(words: set) -> str:
    pos = bool(words & POSITIVE_ANCHORS)
    neg = bool(words & NEGATIVE_ANCHORS)
    if pos and not neg:
        return "pos"
    if neg and not pos:
        return "neg"
    return "both_or_neither"


def is_canonical_line(raw: str) -> bool:
    stripped = raw.strip()
    if not stripped:
        return False
    if stripped.startswith("#"):
        return False
    if stripped.startswith("<!--"):
        return False
    return True


def main(argv):
    # Each entry: (fpath, lineno, raw, keywords, anchor_kind)
    # `keywords` is already anchor-stripped, so the pair loop can
    # intersect directly instead of re-subtracting anchors per pair.
    entries = []
    for fpath in argv:
        try:
            fh = open(fpath, encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"memory_health_check: could not open {fpath}: {exc}", file=sys.stderr)
            continue
        with fh:
            for lineno, raw in enumerate(fh, start=1):
                raw = raw.rstrip("\n")
                if not is_canonical_line(raw):
                    continue
                words = tokenize(raw)
                anchor_kind = classify_anchors(words)
                if anchor_kind == "both_or_neither":
                    continue
                keywords = words - POSITIVE_ANCHORS - NEGATIVE_ANCHORS
                if len(keywords) < MIN_SHARED_KEYWORDS:
                    # Not enough signal to possibly match MIN_SHARED_KEYWORDS.
                    continue
                entries.append((fpath, lineno, raw, keywords, anchor_kind))

    candidates = []
    for i in range(len(entries)):
        for j in range(i + 1, len(entries)):
            a = entries[i]
            b = entries[j]
            if a[4] == b[4]:
                continue  # same direction → not opposing
            shared = a[3] & b[3]
            if len(shared) >= MIN_SHARED_KEYWORDS:
                candidates.append((a, b, shared))

    if not candidates:
        print("No contradiction candidates found.")
        return 0

    print(f"{len(candidates)} contradiction candidate(s) for human review:")
    for a, b, shared in candidates:
        key_preview = ", ".join(sorted(shared)[:5])
        print(f"[CONTRADICTION-CANDIDATE] shared keywords: {key_preview}")
        print(f"  {a[0]}:{a[1]}: {a[2]}")
        print(f"  {b[0]}:{b[1]}: {b[2]}")
    return 0


sys.exit(main(sys.argv[1:]))
PY
fi


# 5. Bypass Detection — commits touching self-improving/** that don't
# reference memory_update.sh. Only considers commits on or after the
# provenance scheme adoption date (PROVENANCE_SPEC_DATE). Commits older
# than that predate the wrapper entirely and cannot be "bypasses."
print_header "Bypass Detection (since $PROVENANCE_SPEC_DATE)"

BYPASS_COUNT=0
while read -r commit_info; do
    if [[ -z "$commit_info" ]]; then continue; fi

    # Format is HASH|AUTHOR|SUBJECT
    IFS='|' read -r hash author subject <<< "$commit_info"

    # Read the full message to search for memory_update.sh
    full_message=$(git log -1 --format="%B" "$hash")

    if ! echo "$full_message" | grep -qi "memory_update.sh"; then
        # Check if author is an agent OR if it has Co-Authored-By with an agent
        if [[ "$author" == "Claude" || "$author" == "Codex" || "$author" == "Gemini" || "$full_message" =~ "Co-Authored-By: " ]]; then
             echo -e "${YELLOW}[BYPASS]${NC} $hash ($author): $subject"
             BYPASS_COUNT=$((BYPASS_COUNT + 1))
        fi
    fi
done < <(git log --since="$PROVENANCE_SPEC_DATE 00:00" --format="%H|%an|%s" -- "$CANONICAL_DIR")

if [[ $BYPASS_COUNT -eq 0 ]]; then
    echo "No bypasses detected."
fi


# 6. Maintenance Canary (The "Neglect" Report)
print_header "Maintenance Canary"

# Files with no recent commits (last 30 days)
for file in $FILES; do
    last_commit_date=$(git log -1 --format="%as" -- "$file")
    if [[ -n "$last_commit_date" ]]; then
        if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
            diff_secs=$(($(date -d "$CURRENT_DATE" +%s) - $(date -d "$last_commit_date" +%s)))
        else
            diff_secs=$(($(date -d "$CURRENT_DATE" +%s) - $(date -d "$last_commit_date" +%s)))
        fi
        diff_days=$((diff_secs / 86400))
        
        if [[ $diff_days -ge $STALE_THRESHOLD_DAYS ]]; then
             echo -e "${YELLOW}[NEGLECTED]${NC} $file ($diff_days days since last commit)"
             warn
        fi
    fi
done

# Coverage reporting is measurement-only for Phase 2. The v2 plan
# explicitly says hard budgets come AFTER 2-3 real session cycles of
# baseline data. Flagging "low coverage" against an arbitrary target
# at this stage would be exactly the kind of arbitrary number the plan
# warned against. The STAMPED/TOTAL number above is the canary — the
# agent can eyeball it without a hardcoded target.

# Observation backlog is informational — no hard threshold yet.
if [[ -f "$OBS_FILE" ]]; then
    if [[ "${TOTAL_OBS:-0}" -gt 0 ]]; then
        echo -e "Observation backlog: $TOTAL_OBS pending (no hard threshold in measurement phase)"
    fi
fi

# File-size reporting is informational — no hard soft-limit yet.
# The TOTAL line in the baseline metrics table is the canary. Report
# the largest file for context, but do NOT set a cutoff.
LARGEST_FILE=""
LARGEST_CHARS=0
for file in $FILES; do
    chars=$(wc -c < "$file" | xargs)
    if [[ $chars -gt $LARGEST_CHARS ]]; then
        LARGEST_CHARS=$chars
        LARGEST_FILE=$file
    fi
done
if [[ -n "$LARGEST_FILE" ]]; then
    echo -e "Largest canonical file: $LARGEST_FILE ($LARGEST_CHARS chars)"
fi

echo -e "\n${BLUE}Health report complete.${NC}"
exit "$EXIT_STATUS"
