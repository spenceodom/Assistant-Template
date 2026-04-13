# Hooks

Three shell hooks drive memory-system behavior during a Claude Code session. All three live in `scripts/` and are wired up in `.claude/settings.json`. Agents rarely need to read this file — the Stop hook prints its own save-pass instructions when it fires, and the preflight runs invisibly. Consult this file when you're changing hook behavior or debugging unexpected hook output.

## `session-nudge.sh` — UserPromptSubmit (preflight)

Fires before the agent processes each user message. Responsibilities:

- Maintains a per-session message counter keyed by `$PPID` at `journal/.session_state_{PPID}`.
- On message #1, nudges the agent to emit the Session Start Protocol fingerprint.
- Injects `[JOURNAL CONTEXT]` headers with warm-grep journal matches relevant to the detected domain. These are hints, not commands (see Session Start Protocol step 5 in `CLAUDE.md`).
- Flags stale buffer files with `[BUFFER FLUSH REQUIRED]` when they belong to dead sessions (see Session Start Protocol step 1).
- Periodically emits `[BUFFER UPDATE DUE]` so the agent refreshes `journal/buffer_{PPID}.md` mid-session.
- Emits the `[SELF-IMPROVING]` passive-observation reminder on every turn.

This is the hook `CLAUDE.md` refers to as "the preflight hook."

## `session-save-hook.sh` — Stop (forced save pass)

Fires when the agent tries to stop. Every `SAVE_INTERVAL` user messages (default 15), the hook returns `{decision: block, reason: "..."}` with a numbered save-pass checklist:

1. Any explicit corrections to append to `corrections.md`?
2. Any observations at `count:3+` ready to graduate to canonical memory?
3. Is the session buffer current with topics / decisions / open loops?
4. If nothing has materially changed, say so and stop.

The anti-loop guard uses Claude Code's `stop_hook_active` flag — after the hook blocks once, the next stop attempt carries the flag and passes through. State lives at `journal/.save_state_<session-id>` keyed by Claude Code `session_id` (NOT `$PPID` — the Stop hook doesn't receive PPID, while UserPromptSubmit doesn't receive session_id; the asymmetry is intentional).

Adapted from MemPalace's `hooks/mempal_save_hook.sh`. The two-`python3`-call pattern in the script is load-bearing on Windows/git-bash — do not collapse it (MSYS path translation only applies to direct argv, not to paths inside JSON strings).

## `session-precompact-hook.sh` — PreCompact

Fires once before Claude Code compacts the conversation. Always blocks with a thorough save reason — no counter, no state, no anti-loop guard (PreCompact fires once per compaction). The block forces the agent to flush the buffer, graduate ready observations, and log pending corrections before compaction destroys detailed context.

Deliberately simpler than the Stop hook. ~40 lines of bash + a heredoc.
