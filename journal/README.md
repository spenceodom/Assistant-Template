# Journal

Append-only session evidence. This folder stores structured recaps of conversations to serve as a searchable safety net alongside canonical memory in `self-improving/`.

## Authority

- `self-improving/` is **always** authoritative. If journal evidence conflicts with canonical memory, canonical memory wins.
- Journal entries are **never** deleted or rewritten.
- Promotions from journal to canonical memory happen only on high-confidence signals (explicit corrections, "remember this", repeated patterns).

## Files

| File | Purpose |
|------|---------|
| `YYYY-MM.md` | Monthly journal. One file per calendar month. Append-only. |
| `buffer_{PPID}.md` | Session-specific scratch file. Updated periodically during a session. Flushed into the monthly journal at the start of the next session, then cleared. |
| `.session_state_{PPID}` | Operational state: message counter only. Auto-created by hook. |
| `.journal_paused_{PPID}` | OTR toggle. Exists while journaling is paused ("off the record") for that session. Deleted on "resume logging" or session end. |

## Entry Format

Each entry in a monthly journal file follows this structure:

```markdown
## YYYY-MM-DD HH:MM - [short topic description]
Agent: [claude|codex|gemini]
Domains: [detected domains, comma-separated]
People: [mentioned people]
Projects: [active projects]
Topics: [key topics discussed]
Decisions:
- [decisions made during the session]
Open loops:
- [unresolved items or questions]
Potential promotions:
- [candidates for promotion to canonical memory]
```

## Boundary Rules

Journal entries must **never** include:
- Passwords, API keys, tokens, or credentials
- Full bank/card numbers or crypto seed phrases
- Other people's personal information without consent
- Detailed location patterns (home/work addresses, daily routines)

When in doubt, generalize instead of logging literally.

## Off the Record

If the user says "don't log this" or "off the record":
- A `.journal_paused_{PPID}` file is created
- Buffer updates are suppressed until the user says "resume logging" or the session ends
- The hook will emit `[JOURNALING PAUSED]` as a reminder

## Buffer Lifecycle

1. During a session, the hook nudges the AI to update `buffer_{PPID}.md` every ~15 messages
2. The buffer is session-aware: each checkpoint **updates in place** (one session = one evolving entry)
3. If the terminal is closed mid-session, the buffer survives on disk
4. At the start of the next session, the hook detects non-empty buffer files and emits `[BUFFER FLUSH REQUIRED]`
5. The AI flushes each buffer into `journal/YYYY-MM.md` and clears the buffer file
6. PPID-specific scratch files are gitignored; monthly journals are tracked
