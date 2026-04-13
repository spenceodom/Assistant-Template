#!/usr/bin/env bash
# session-precompact-hook.sh — Claude Code "PreCompact" hook that forces an
# emergency canonical memory save before the conversation gets compacted.
#
# Adapted from the MemPalace pattern (github.com/milla-jovovich/mempalace
# hooks/mempal_precompact_hook.sh) but targeting our gated write path.
#
# Unlike session-save-hook.sh (which fires every SAVE_INTERVAL user messages),
# this hook ALWAYS blocks — compaction means the agent is about to lose detailed
# context about what was discussed, and that's always worth pausing to capture.
#
# How it works:
#   1. Claude Code sends JSON on stdin: { session_id, ... }
#   2. We unconditionally return { decision: block, reason: "..." } instructing
#      the agent to save everything important to canonical memory + the buffer
#      before compaction proceeds.
#   3. Claude Code has its own anti-infinite-loop guard here — PreCompact fires
#      once per compaction cycle, not continuously.
#
# Install (.claude/settings.json):
#   "PreCompact": [{
#     "matcher": "",
#     "hooks": [{ "type": "command", "command": "bash ./scripts/session-precompact-hook.sh", "timeout": 30 }]
#   }]

set -u

# PreCompact doesn't need state files, transcript counting, or session tracking.
# It always blocks. We still read stdin so we don't leave the hook process
# hanging on Claude Code's JSON write.
INPUT="$(cat 2>/dev/null || true)"
: "${INPUT:=}"  # silence shellcheck's unused-var warning under set -u

cat <<'HOOKJSON'
{
  "decision": "block",
  "reason": "COMPACTION IMMINENT. Claude Code is about to compress the conversation and detailed context will be lost. Take a thorough save pass before compaction proceeds:\n\n1. Flush the current session buffer — rewrite journal/buffer_${PPID}.md in place with a structured entry per journal/README.md (## header, Agent, Domains, People, Projects, Topics, Decisions, Open loops, Potential promotions). Be THOROUGH — after compaction you may not remember the details, so capture them now.\n2. Promote any high-confidence observations. If any entry in self-improving/observations.md has reached count>=3 and there is time, graduate it to the right canonical file via `scripts/memory_update.sh add <file> --content '<text> | source: observation:<first-date>-<slug>'`.\n3. Log any explicit corrections from this session to self-improving/corrections.md that aren't already there.\n4. Update any affected domain memory files with facts, decisions, or open loops that should survive the compaction — use scripts/memory_update.sh for the writes so provenance is enforced.\n5. Briefly note in your response what was saved so the post-compaction summary has something concrete to reference.\n\nUse scripts/memory_update.sh for all canonical writes. When done, stop normally and compaction will proceed."
}
HOOKJSON
