#!/usr/bin/env bash
# session-save-hook.sh — Claude Code "Stop" hook that forces a canonical
# memory save pass every N user messages.
#
# Adapted from the MemPalace save-hook pattern (github.com/milla-jovovich/mempalace)
# but targeting our gated write path (scripts/memory_update.sh) and canonical
# files under self-improving/** instead of ChromaDB / MCP tools.
#
# How it works:
#   1. Claude Code sends JSON on stdin: { session_id, stop_hook_active, transcript_path }
#   2. If stop_hook_active is true, we return {} (lets the stop happen).
#      This is the anti-infinite-loop guard — after we block once, Claude Code
#      re-runs the hook with stop_hook_active=true on the next stop attempt.
#   3. Otherwise, count user messages in the transcript JSONL, compare against
#      the saved checkpoint for this session_id, and if SINCE_LAST >= SAVE_INTERVAL,
#      return { decision: block, reason: "..." } to force the agent to take a
#      save pass before stopping.
#
# State files live under journal/.save_state_<session-id> (gitignored).
#
# Install (.claude/settings.json):
#   "Stop": [{
#     "matcher": "",
#     "hooks": [{ "type": "command", "command": "bash ./scripts/session-save-hook.sh" }]
#   }]
#
# Testing overrides:
#   MEMORY_SAVE_INTERVAL=2 bash scripts/session-save-hook.sh < fixture.json
#   MEMORY_SAVE_STATE_DIR=/tmp/state bash scripts/session-save-hook.sh < fixture.json

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${MEMORY_SAVE_STATE_DIR:-$PROJECT_DIR/journal}"

SAVE_INTERVAL="${MEMORY_SAVE_INTERVAL:-15}"

mkdir -p "$STATE_DIR" 2>/dev/null || true

# --- Parse hook input ---
# NOTE on two python3 calls: we parse JSON here, then invoke python3 a SECOND
# time below with TRANSCRIPT_PATH as a direct argv. On MSYS/git-bash this is
# load-bearing — MSYS translates `/tmp/...` style paths into native Windows
# paths only when they appear as argv to a non-MSYS binary, not when they're
# embedded inside a JSON string. Collapsing to one call breaks path
# resolution on Windows.
INPUT="$(cat)"

SESSION_ID=""
STOP_HOOK_ACTIVE="false"
TRANSCRIPT_PATH=""

PARSED="$(python3 - "$INPUT" 2>/dev/null <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

def sh_escape(s):
    return "'" + str(s).replace("'", "'\\''") + "'"

sid = data.get("session_id", "") if isinstance(data, dict) else ""
sha = bool(data.get("stop_hook_active", False)) if isinstance(data, dict) else False
tp  = data.get("transcript_path", "") if isinstance(data, dict) else ""

print("SESSION_ID=" + sh_escape(sid))
print("STOP_HOOK_ACTIVE=" + ("true" if sha else "false"))
print("TRANSCRIPT_PATH=" + sh_escape(tp))
PY
)" || PARSED=""

# shellcheck disable=SC1090
if [ -n "$PARSED" ]; then
  eval "$PARSED"
fi

# Sanitize session_id for use as a filename — only alnum, underscore, hyphen.
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9_-')"
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"

# Expand ~ if present in transcript path.
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

# --- Anti-infinite-loop guard ---
# If Claude Code is retrying the stop after our previous block, let it through.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  printf '{}\n'
  exit 0
fi

# --- Count user messages in the transcript JSONL ---
# Pass TRANSCRIPT_PATH as argv (not stdin, not embedded) so MSYS/git-bash can
# translate MSYS-style paths into native Windows paths for python3.
EXCHANGE_COUNT=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  EXCHANGE_COUNT="$(python3 - "$TRANSCRIPT_PATH" 2>/dev/null <<'PY'
import json, sys
count = 0
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                entry = json.loads(line)
            except Exception:
                continue
            msg = entry.get("message") if isinstance(entry, dict) else None
            if not isinstance(msg, dict):
                continue
            if msg.get("role") != "user":
                continue
            content = msg.get("content", "")
            # Slash-command stubs aren't real user turns.
            if isinstance(content, str) and "<command-message>" in content:
                continue
            count += 1
except Exception:
    count = 0
print(count)
PY
)" || EXCHANGE_COUNT=0
fi

case "$EXCHANGE_COUNT" in
  ''|*[!0-9]*) EXCHANGE_COUNT=0 ;;
esac

# --- Load last-save checkpoint ---
LAST_SAVE_FILE="$STATE_DIR/.save_state_${SESSION_ID}"
LAST_SAVE=0
if [ -f "$LAST_SAVE_FILE" ]; then
  STORED="$(cat "$LAST_SAVE_FILE" 2>/dev/null || printf '0')"
  case "$STORED" in
    ''|*[!0-9]*) LAST_SAVE=0 ;;
    *) LAST_SAVE="$STORED" ;;
  esac
fi

SINCE_LAST=$((EXCHANGE_COUNT - LAST_SAVE))

# --- Decide: save or let stop happen ---
if [ "$SINCE_LAST" -ge "$SAVE_INTERVAL" ] && [ "$EXCHANGE_COUNT" -gt 0 ]; then
  # If we can't persist the checkpoint (read-only state dir, full disk, etc.)
  # do NOT block — otherwise the hook would fire on every stop forever.
  if ! printf '%s\n' "$EXCHANGE_COUNT" > "$LAST_SAVE_FILE" 2>/dev/null; then
    printf '{}\n'
    exit 0
  fi
  cat <<'HOOKJSON'
{
  "decision": "block",
  "reason": "FORCED-SAVE checkpoint. Every 15 user messages this hook blocks the stop so canonical memory can catch up with the session. Take a short save pass before trying to stop again:\n\n1. Any explicit corrections from this session that are not yet in self-improving/corrections.md? If so, append them via `scripts/memory_update.sh add self-improving/corrections.md --content '<text>'`. corrections.md is exempt from the inline provenance stamp requirement, so no `| source:` suffix is needed — the wrapper still runs boundary and threat lint.\n2. Any observations in self-improving/observations.md that have reached count>=3 across sessions and should graduate? Promote them to the appropriate canonical file via `scripts/memory_update.sh add <file> --content '<text> | source: observation:<first-date>-<slug>'`.\n3. Is journal/buffer_${PPID}.md current with this session's topics / decisions / open loops? If not, rewrite it in place (one evolving entry per session).\n4. If nothing has materially changed since the last save, say so in one line and stop.\n\nUse scripts/memory_update.sh for all canonical writes — never raw Edit. Skip this pass entirely if you are mid-tool-sequence and stopping would break something. After the save pass completes, the next stop attempt will carry stop_hook_active=true and this hook will let it through."
}
HOOKJSON
else
  printf '{}\n'
fi
