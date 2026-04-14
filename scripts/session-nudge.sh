#!/bin/bash
# session-nudge.sh — Preflight hook for the Hybrid Markdown Memory system.
# Runs on every UserPromptSubmit. Injects context and reminders into the AI's prompt.
#
# Responsibilities:
#   1. Self-improving reminders (corrections, observations)
#   2. Buffer flush detection (non-empty buffers from prior sessions)
#   3. Domain keyword detection on user message
#   4. Warm Grep: compact journal header injection for detected domains
#   5. Buffer update nudge (every N messages)
#   6. OTR (off-the-record) toggle awareness

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JOURNAL_DIR="$PROJECT_DIR/journal"
SESSION_ID="$PPID"

STATE_FILE="$JOURNAL_DIR/.session_state_${SESSION_ID}"
BUFFER_FILE="$JOURNAL_DIR/buffer_${SESSION_ID}.md"
PAUSED_FILE="$JOURNAL_DIR/.journal_paused_${SESSION_ID}"

NUDGE_INTERVAL=10
MAX_JOURNAL_MATCHES=5
WARM_GREP_MONTHS=3

# Read user message from stdin (Claude Code pipes it to the hook)
USER_MESSAGE=""
if [ ! -t 0 ]; then
  USER_MESSAGE="$(cat)"
fi

# --- 1. Self-improving reminders (always emitted) ---
echo "[SELF-IMPROVING] If the user corrected you or stated a preference, log it to the appropriate memory file. Observe: does this message reveal a communication pattern, personality trait, or preference not already in profile.md? If so, check observations.md for an existing match — increment count and update last date if found, or append a new entry with count:1 if not. Format: - [count:N] [first:YYYY-MM-DD] [last:YYYY-MM-DD] Description (rationale: optional, only when clearly obvious)"

# --- 2. Buffer flush detection ---
# Check for non-empty buffer files from OTHER sessions (not our own)
STALE_BUFFERS=""
for buf in "$JOURNAL_DIR"/buffer_*.md; do
  [ -f "$buf" ] || continue
  if [ -s "$buf" ]; then
    BUF_PID="$(echo "$buf" | sed 's/.*buffer_\(.*\)\.md/\1/')"
    if [ "$BUF_PID" != "$SESSION_ID" ]; then
      # Check if the owning process is still running; if not, it's stale
      if ! kill -0 "$BUF_PID" 2>/dev/null; then
        STALE_BUFFERS="${STALE_BUFFERS} $(basename "$buf")"
      fi
    fi
  fi
done

if [ -n "$STALE_BUFFERS" ]; then
  # Guardrail: only inject the first stale buffer inline to avoid prompt bloat
  FIRST_STALE="$(echo "$STALE_BUFFERS" | awk '{print $1}')"
  REMAINING_STALE="$(echo "$STALE_BUFFERS" | awk '{$1=""; print $0}' | xargs)"
  MAX_HANDOFF_LINES=50

  echo "[SESSION HANDOFF] Stale buffer from ended session: $FIRST_STALE"
  echo "This is your handoff from the previous session. Contents below:"
  echo "---"
  buf_path="$JOURNAL_DIR/$FIRST_STALE"
  if [ -f "$buf_path" ]; then
    LINE_COUNT=$(wc -l < "$buf_path")
    if [ "$LINE_COUNT" -gt "$MAX_HANDOFF_LINES" ]; then
      tail -n "$MAX_HANDOFF_LINES" "$buf_path"
      echo "[TRUNCATED — showing last $MAX_HANDOFF_LINES of $LINE_COUNT lines. Read full file if needed.]"
    else
      cat "$buf_path"
    fi
  fi
  echo "---"
  echo "[ACTION] Read the Open loops and Suggested next action above — these tell you where to pick up. Flush this buffer into journal/YYYY-MM.md (use the date from the entry's ## header, NOT today's date), then delete the buffer file."

  if [ -n "$REMAINING_STALE" ]; then
    echo "[ADDITIONAL STALE BUFFERS] Also flush these (read them manually):$REMAINING_STALE"
  fi
fi

# --- 3. Message counter ---
MSG_NUM=1
if [ -f "$STATE_FILE" ]; then
  MSG_NUM=$(( $(cat "$STATE_FILE") + 1 ))
fi
echo "$MSG_NUM" > "$STATE_FILE"

echo "[SESSION: message #${MSG_NUM}]"

# --- 3a. Session-start checklist reminder (message #1 only) ---
if [ "$MSG_NUM" = "1" ]; then
  echo "[SESSION-START CHECKLIST] Work through the Session Start Protocol in CLAUDE.md before responding. After completing it, include a one-line fingerprint in your first response: [session-start profile=ok memory=ok corrections=ok observations=ok domain=<name-or-none> buffer=<clean|flushed:N>]. This creates a grep-able audit trail."
fi

# --- 4. OTR check ---
if [ -f "$PAUSED_FILE" ]; then
  echo "[JOURNALING PAUSED] Off-the-record mode is active. Do not update buffer or journal. Resume when the user says \"resume logging\" or \"back on the record\" (delete $PAUSED_FILE to resume)."
fi

# --- 5. OTR trigger detection ---
if echo "$USER_MESSAGE" | grep -qi -E "don't log this|off the record|stop logging|pause journal"; then
  touch "$PAUSED_FILE"
  echo "[JOURNALING PAUSED] User requested off-the-record mode. Journaling paused for this session."
fi

if echo "$USER_MESSAGE" | grep -qi -E "resume logging|back on the record|start logging|resume journal"; then
  if [ -f "$PAUSED_FILE" ]; then
    rm -f "$PAUSED_FILE"
    echo "[JOURNALING RESUMED] Off-the-record mode ended. Journal updates will resume."
  fi
fi

# --- 6. Domain keyword detection ---
detect_domains() {
  local msg="$1"
  local domains=""

  if echo "$msg" | grep -qi -E "health|fitness|diet|exercise|gym|nutrition|weight|workout|bench|squat|deadlift|cardio|calories|protein|body\s?fat"; then
    domains="${domains}health-fitness,"
  fi
  if echo "$msg" | grep -qi -E "game|gaming|PC spec|console|stream|pokemon|romhack|playstation|xbox|nintendo|steam"; then
    domains="${domains}gaming,"
  fi
  if echo "$msg" | grep -qi -E "career|job|colleague|workplace|office|salary|capita|interview|employer|promotion|resume|linkedin"; then
    domains="${domains}work,"
  fi
  if echo "$msg" | grep -qi -E "bank|invest|budget|money|account|portfolio|stock|crypto|robinhood|401k|tax|mortgage|savings|debt"; then
    domains="${domains}finance,"
  fi
  if echo "$msg" | grep -qi -E "software|hardware|gadget|app|tool|code|programming|deploy|server|docker|api|database|MCP|claude code"; then
    domains="${domains}tech,"
  fi

  # Trim trailing comma
  echo "$domains" | sed 's/,$//'
}

DETECTED_DOMAINS=""
if [ -n "$USER_MESSAGE" ]; then
  DETECTED_DOMAINS="$(detect_domains "$USER_MESSAGE")"
fi

# --- 7. Warm Grep: search recent journal files for detected domains ---
if [ -n "$DETECTED_DOMAINS" ] && [ ! -f "$PAUSED_FILE" ]; then
  # Build list of recent monthly journal files (last N months)
  JOURNAL_FILES=""
  for i in $(seq 0 $((WARM_GREP_MONTHS - 1))); do
    if command -v gdate &>/dev/null; then
      YM="$(gdate -d "today - $i months" +%Y-%m)"
    else
      YM="$(date -d "today - $i months" +%Y-%m 2>/dev/null)"
    fi
    # Fallback for systems where date -d doesn't work (e.g., some Windows/MSYS)
    if [ -z "$YM" ]; then
      # Manual calculation: current year-month minus i months
      YEAR=$(date +%Y)
      MONTH=$(date +%-m)
      MONTH=$((MONTH - i))
      while [ "$MONTH" -le 0 ]; do
        MONTH=$((MONTH + 12))
        YEAR=$((YEAR - 1))
      done
      YM="$(printf '%d-%02d' "$YEAR" "$MONTH")"
    fi
    if [ -f "$JOURNAL_DIR/${YM}.md" ]; then
      JOURNAL_FILES="$JOURNAL_FILES $JOURNAL_DIR/${YM}.md"
    fi
  done

  if [ -n "$JOURNAL_FILES" ]; then
    # For each detected domain, grep for matching entries and extract headers
    # Collect ALL matches first, then dedup and cap at output time
    RAW_MATCHES=""

    IFS=',' read -ra DOMAIN_ARR <<< "$DETECTED_DOMAINS"
    for domain in "${DOMAIN_ARR[@]}"; do
      [ -z "$domain" ] && continue
      # Search for entries whose Domains: line contains this domain
      # Extract the ## header line and Decisions line(s) for context
      while IFS= read -r file; do
        [ -f "$file" ] || continue
        # Use awk to find matching sections and extract compact headers
        RESULT="$(awk -v domain="$domain" '
          /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
            header = $0
            agent = ""; domains = ""; decision = ""
            in_decisions = 0
          }
          /^Agent:/ { agent = $0 }
          /^Domains:/ {
            domains = $0
            if (tolower(domains) ~ tolower(domain)) { found = 1 } else { found = 0 }
          }
          /^Decisions:/ { in_decisions = 1; next }
          in_decisions && /^- / { if (decision == "") decision = $0; next }
          in_decisions && !/^- / { in_decisions = 0 }
          /^(Open loops|Potential promotions|Topics|People|Projects):/ { in_decisions = 0 }
          /^$/ {
            if (found == 1 && header != "") {
              sub(/^## /, "", header)
              sub(/^- /, "", decision)
              if (decision != "") {
                print "- " header " | " decision
              } else {
                print "- " header
              }
              found = 0; header = ""
            }
          }
          END {
            if (found == 1 && header != "") {
              sub(/^## /, "", header)
              sub(/^- /, "", decision)
              if (decision != "") {
                print "- " header " | " decision
              } else {
                print "- " header
              }
            }
          }
        ' "$file")"

        if [ -n "$RESULT" ]; then
          RAW_MATCHES="${RAW_MATCHES}${RESULT}\n"
        fi
      done <<< "$(echo "$JOURNAL_FILES" | tr ' ' '\n')"
    done

    # Deduplicate, then cap at MAX_JOURNAL_MATCHES unique entries
    MATCHES="$(echo -e "$RAW_MATCHES" | awk 'NF && !seen[$0]++' | head -n "$MAX_JOURNAL_MATCHES")"

    if [ -n "$MATCHES" ]; then
      echo "[JOURNAL CONTEXT — ${DETECTED_DOMAINS} detected]"
      echo "$MATCHES"
      echo "[End journal context — read full entries only if relevant to this message]"
    else
      echo "[JOURNAL CONTEXT — ${DETECTED_DOMAINS} detected — no recent journal matches]"
    fi
  fi
fi

# --- 8. Buffer update nudge ---
if [ ! -f "$PAUSED_FILE" ] && [ $((MSG_NUM % NUDGE_INTERVAL)) -eq 0 ]; then
  echo "[BUFFER UPDATE DUE] Update journal/buffer_${SESSION_ID}.md as your rolling checkpoint. Use the entry format from journal/README.md. Update in place (one evolving entry per session). Keep these sections current — they are the handoff if this session ends unexpectedly:"
  echo "  - Open loops: unresolved items (keep actionable)"
  echo "  - Suggested next action: what should happen next"
  echo "  - Active arcs: which life arcs this session advances (if any)"
fi
