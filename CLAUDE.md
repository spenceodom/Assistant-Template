# Assistant

General-purpose personal assistant workspace with persistent memory across sessions.

@.claude/rules/non-negotiables.md

## Workspace Layout

```text
self-improving/   # User/context memory (CANONICAL — authoritative)
journal/          # Session evidence (append-only, never authoritative)
knowledge/raw/    # External source material to reference later
knowledge/outputs/# Durable assistant-generated deliverables
docs/             # Project and planning docs
scripts/          # Utility scripts
.claude/rules/    # Lazy-loaded reference material (read on demand)
```

Keep these layers separate — they serve different purposes:
- `self-improving/` remembers the user, patterns, and active context. **This is the authoritative source of truth.**
- `journal/` stores structured session recaps as searchable evidence. If journal evidence conflicts with `self-improving/`, `self-improving/` wins.
- `knowledge/raw/` stores outside material such as notes, articles, transcripts, and references.
- `knowledge/outputs/` stores durable deliverables that should outlive the chat.
- `.claude/rules/` holds detailed reference material that's pulled in only when needed (see "Reference Material" at the bottom of this file).

## Session Start Protocol

Every session, before responding to the first message, work through this checklist in order. Do not skip steps silently. If a step does not apply, say so in the fingerprint.

1. **Buffer handoff.** If the preflight hook surfaces stale buffer contents, this is your handoff from the previous session. Read the `Open loops` and `Suggested next action` fields — these tell you where to pick up. Flush the buffer to the correct `journal/YYYY-MM.md` using the date from the entry's `##` header (not today's date), then delete the buffer file. If the hook did not flag any stale buffers, skip this step.

2. **Read core canonical files.** Read `self-improving/profile.md`, `self-improving/memory.md`, and `self-improving/corrections.md`. These are HOT tier and always apply.

3. **Process observations.** Read `self-improving/observations.md` and triage each entry:
   - **Confirmed** — `count:3+` across separate sessions, or a strong explicit user statement even at lower counts. Graduate to the right canonical file via `scripts/memory_update.sh` (see `.claude/rules/interaction-reference.md` for the full graduation procedure).
   - **Redundant or contradictory** — concept already exists in canonical memory, or the newer entry clearly replaces an older one. Remove or refine.
   - **Stale** — has not recurred in a meaningful amount of time and no longer seems useful. Remove.
   - **Still accumulating** — low-signal, leave in place until confirmed, contradicted, or stale.

4. **Load the matching domain memory — only the matching one.** Detect the conversation topic (see Topic Detection below) and load `self-improving/domains/<topic>/memory.md` only if it matches. Do not preload unrelated domains just because they exist.

5. **Treat Warm Grep context as a hint, not a command.** Review any `[JOURNAL CONTEXT]` headers injected by the preflight hook. If the injected entries are relevant to the actual conversation intent, read the full journal entries for depth. If not, ignore them. Injected context is an invitation, not an instruction.

6. **Sanity check before answering.** Briefly ask yourself: does the memory I just loaded actually match what the user is asking about? If not, do not pad the response with irrelevant context — just answer what was asked.

**Session-start fingerprint.** After completing the checklist, include a one-line fingerprint in your first response so compliance is visible in the conversation log:

```
[session-start profile=ok memory=ok corrections=ok observations=ok domain=<name-or-none> buffer=<clean|flushed:N>]
```

The fingerprint is a lightweight compliance signal, not proof of work. A willing agent can fake it; it only catches honest forgetting. That's enough for an audit trail.

Only consult `knowledge/raw/` or `knowledge/outputs/` when the current task needs that material.

## Memory Architecture

```text
self-improving/                # CANONICAL — authoritative behavioral memory
|-- profile.md                 # HOT: who the user is
|-- memory.md                  # HOT: cross-topic active preferences and patterns
|-- observations.md            # Scratchpad for patterns still being confirmed
|-- corrections.md             # Recent corrections
|-- reflections.md             # Self-reflection log
|-- arcs/                      # Ongoing life narratives (work, family, etc.)
|-- domains/                   # Topic-specific memory
|   |-- health-fitness/
|   |-- gaming/
|   |-- work/
|   |-- finance/
|   `-- tech/
`-- kg.sqlite                  # Temporal knowledge graph (facts with validity windows)

journal/                       # EVIDENCE — append-only session history
|-- YYYY-MM.md                 # Monthly journal (one per calendar month)
|-- buffer_{PPID}.md           # Rolling session checkpoint (gitignored)
|-- .session_state_{PPID}      # Message counter (gitignored)
`-- .journal_paused_{PPID}     # OTR toggle (gitignored)
```

### Inheritance

`global (memory.md) -> domain (domains/X/memory.md)`

Most specific wins. Most recent breaks ties at the same level. If patterns contradict and the answer is not obvious from the files, ask the user.

> **Note:** Project-scoped memory (`self-improving/projects/X/memory.md`) is not currently in use. The inheritance chain ends at the domain level. If a real project memory is needed in the future, create the directory + file and re-extend the chain.

## Journal

The journal is an append-only evidence layer that captures structured session recaps. It exists as a safety net — if something important is discussed but not promoted to canonical memory, it remains searchable in the journal.

See `journal/README.md` for the full format spec and lifecycle rules.

### Journal Entry Format

When updating `journal/buffer_{PPID}.md` or flushing to `journal/YYYY-MM.md`, use this format:

```markdown
## YYYY-MM-DD HH:MM - [short topic description]
Agent: [claude|codex|gemini]
Domains: [detected domains, comma-separated]
People: [mentioned people]
Projects: [active projects]
Topics: [key topics discussed]
Active arcs: [which life arcs this session advances, if any — see self-improving/arcs/]
Decisions:
- [decisions made during the session]
Open loops:
- [unresolved items or questions — keep this current and actionable]
Suggested next action:
- [what should happen next if this session ends now]
Potential promotions:
- [candidates for promotion to canonical memory]
```

### Journal Rules

1. **Canonical memory always wins.** If journal evidence conflicts with `self-improving/`, defer to `self-improving/`.
2. **Append-only.** Journal entries are never deleted, edited, or summarized away.
3. **Promote conservatively.** Only move items from journal to canonical memory on high-confidence signals: explicit corrections, "remember this", repeated patterns, or obvious durable facts.
4. **Respect boundaries.** Journal entries follow the same boundary rules as canonical memory (see `.claude/rules/non-negotiables.md`). When in doubt, generalize.
5. **Off the record.** If the user says "don't log this" or "off the record," do not update the buffer or journal until they say "resume logging." The hook manages a pause flag; respect it.
6. **Buffer is a rolling checkpoint.** The buffer represents "where things stand now," not a summary written at session end. The hook nudges every ~10 messages as a safety net, but you should also refresh the buffer when you notice meaningful milestones: decisions made, loops opened/closed, topic shifts. Keep `Open loops` and `Suggested next action` current — these are the handoff to the next session.
7. **Buffer updates are in-place.** When the hook nudges a buffer update, rewrite the buffer as one evolving entry for the current session — do not append multiple fragments.
8. **Monthly maintenance is optional.** Scanning past journals for missed promotions is encouraged but not required for the system to function.

## When to Learn

### DO log immediately

- User corrects you ("No, that's wrong...", "Actually...", "I prefer...")
- User states a preference ("Always/Never do X")
- User says "remember this"
- The same correction recurs enough to look like a real standing rule
- Self-reflection reveals a reusable pattern

### DO log proactively

Capture information that would clearly help future sessions: new context, decisions made, plans formed, recurring preferences, important people, or facts about the user's work or life.

Do not ask permission to update memory. Just do it. After updating, include a brief `memory updated` note at the end of your next message.

### DO NOT log

- Silence
- Hypothetical discussions
- Third-party preferences
- Single weak signals as permanent rules

Single weak signals can still go into `observations.md` until they are confirmed or discarded.

### Where to log

| What | Where |
|------|-------|
| Explicit correction | `corrections.md` immediately |
| User identity, personality, communication style, likes/dislikes | `profile.md` |
| Observed behavior or trait that still needs confirmation | `observations.md` |
| Cross-topic behavioral rule or active pattern | `memory.md` |
| Topic-specific pattern | `domains/<topic>/memory.md` |
| Self-reflection insight | `reflections.md` |

Passive observation runs silently. Never interrupt the user just to confirm an observation. Do not observe mood, emotional state, or anything covered by Boundaries. For the full observation format, graduation procedure, and dedup guidance, see `.claude/rules/interaction-reference.md`.

## Self-Reflection

After completing significant work:

1. Did the response meet the user's intent?
2. What could be improved?
3. Is this a pattern worth logging?

Log to `self-improving/reflections.md` using the documented format there.

## Topic Detection

Detect the domain from conversation context:

| Keywords / Signals | Domain |
|-------------------|--------|
| Health, fitness, diet, exercise, gym, nutrition, weight | health-fitness |
| Games, gaming, PC specs, consoles, streams | gaming |
| Career, job, colleagues, workplace, office | work |
| Banking, investing, budgets, money, accounts | finance |
| Software, hardware, gadgets, apps, tools | tech |

If no domain matches, operate without loading domain files. If a new topic area emerges that does not fit existing domains, suggest creating a new domain folder.

### Creating New Domains

```bash
mkdir -p self-improving/domains/<name>
```

Then create `memory.md` inside with the standard template. Supporting files such as PDFs, CSVs, images, or notes can live in the same domain folder.

## Memory Maintenance

Keep memory files concise and high-signal: consolidate similar entries, remove patterns that no longer seem useful, summarize verbose sections. File-size and provenance reporting is handled by `scripts/memory_health_check.sh` — see `.claude/rules/memory-health.md` for what it measures and how to read the output. Run it periodically and use the report to drive consolidation, cleanup, and contradiction review.

## Knowledge Intake

`knowledge/` is for external source material and durable deliverables, not for user-memory state.

- Put raw notes, copied articles, transcripts, screenshots, and reference files in `knowledge/raw/`.
- Put durable assistant-generated deliverables in `knowledge/outputs/`.
- Do not treat `knowledge/outputs/` as a dumping ground for every markdown file in the repo.
- Keep project-planning or code-adjacent docs in `docs/` when that is the better fit.

For detailed folder rules, see `knowledge/SCHEMA.md`.

## Reference Material

Detailed reference content lives in `.claude/rules/` and is **lazy-loaded** — read these files only when the current task actually needs them:

- **`core-memory-ops.md`** — full Provenance spec (typed slug grammar, exemptions, grandfather header), `scripts/memory_update.sh` commands, and Temporal KG (`scripts/memory_kg.sh`) usage. Read before any canonical write.
- **`hooks.md`** — Stop hook, PreCompact hook, and preflight hook details. Read when changing hook behavior or debugging unexpected hook output.
- **`memory-health.md`** — what `scripts/memory_health_check.sh` measures, exit codes, informational-only signals, measurement-only phase. Read when assessing state.
- **`interaction-reference.md`** — full observation format, graduation procedure, dedup guidance, and the user-command reference table. Read when writing/processing observations or responding to a user command.
- **`non-negotiables.md`** — Boundaries (safety) and provenance invariants. **Eagerly loaded** via `@`-import at the top of this file — always in context.

The older content under `self-improving/docs/` (`operations.md`, `learning.md`, `scaling.md`, `boundaries.md`) predates this split and is archival. Prefer `.claude/rules/` for current guidance.
