# Interaction Reference

Full passive-observation format and user-command reference. This file is lazy-loaded — consult it when you're about to write an observation, process existing observations, or respond to a user command. The short-form version (watch for signals, append to `observations.md`, triage at session start) lives in `CLAUDE.md`.

## Observation Format

Every observation in `self-improving/observations.md` uses this format:

```text
- [count:N] [first:YYYY-MM-DD] [last:YYYY-MM-DD] Description of observed behavior
- [count:N] [first:YYYY-MM-DD] [last:YYYY-MM-DD] Description — rationale: optional interpretation of why this pattern matters
```

Example:

```text
- [count:2] [first:2026-03-20] [last:2026-03-25] Prefers to approve work by saying "looks good" rather than explicit "yes"
- [count:3] [first:2026-03-10] [last:2026-04-02] Asks for independent second opinions from different models on architectural decisions — rationale: triangulation is a deliberate methodology, not indecision
```

`count`, `first`, and `last` are the evidence trail that makes cross-session judgment possible. `rationale` is **optional** and explicitly captures agent interpretation — not durable fact. If the rationale isn't obvious, don't invent one; just record the pattern.

## Writing a New Observation

Watch for signals that reveal who the user is:
- Communication style
- Personality traits
- Likes and dislikes
- Interests and passions
- Work habits

When something noteworthy is observed:
1. Check whether a matching observation already exists in `observations.md`.
2. If yes, increment the count and update the `last` date.
3. If no, append a new entry with `count:1`.
4. Add a `rationale:` clause only when the "why this matters" is genuinely clear — otherwise leave it off.

### Do NOT observe

- Mood or emotional state
- Anything covered by the Boundaries rules in `.claude/rules/non-negotiables.md`

## Deduplication

Before adding or merging an observation, scan `observations.md` (and the target canonical file, if graduating) for the same concept expressed differently. Keep the clearest version instead of storing duplicates.

## Graduating an Observation

When an observation has enough evidence to move out of the scratchpad into canonical memory:

1. Confirm: usually `count:3+` across separate sessions, OR a strong explicit user statement even without a high count.
2. Check the target canonical file for duplicates or better wording.
3. Promote via `scripts/memory_update.sh add <target-file> --content '<text> | source: observation:<first-date>-<slug>'`.
4. Remove the observation from `observations.md` (use `memory_update.sh remove` with the exact text).

The `<target-file>` should match the observation's scope: personal identity → `profile.md`, cross-topic behavioral rule → `memory.md`, topic-specific → `domains/<topic>/memory.md`.

## User Commands

| Say this | Action |
|----------|--------|
| "What do you know about X?" | Search all tiers, show matches with sources |
| "Show my profile" | Display `profile.md` |
| "Show my memory" | Display `memory.md` |
| "Show [domain] memory" | Load and display that domain's `memory.md` |
| "Forget X" | Remove from all tiers (confirm first) |
| "Forget everything" | Export to file, then full wipe |
| "What changed recently?" | Show recent corrections |
| "Memory stats" | Run `scripts/memory_health_check.sh` and show the baseline metrics |
| "Remember X" | Log to the appropriate tier based on context |
| "Show journal" | Display the current month's journal file |
| "Don't log this" | Pause journaling for the current segment |
| "Resume logging" | Resume journaling after an off-the-record segment |
