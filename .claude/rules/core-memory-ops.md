# Core Memory Operations

How to write canonical memory. Read this before any canonical write (`self-improving/**/*.md` or the temporal KG at `self-improving/kg.sqlite`). This file is lazy-loaded — only consult it when actually writing.

## Provenance

Every entry promoted into canonical memory carries a `source:` backlink pointing to the evidence that justified promotion.

### Required shape

```text
- Canonical fact or preference. | source: <type>:<ref>
```

`<type>` must be one of: `journal`, `observation`, `correction`, `user`, `legacy`.

### Allowed types and slug grammars

| Type | Ref shape | Meaning | Example |
|---|---|---|---|
| `journal` | `YYYY-MM.md#YYYY-MM-DD-HHMM-topic-slug` | Anchored to a specific journal entry header | `journal:2026-04.md#2026-04-10-1135-memory-review` |
| `observation` | `YYYY-MM-DD-description-slug` | Graduated from an observation; date is the observation's `first:` date | `observation:2026-04-10-triangulates-with-multiple-ai-opinions` |
| `correction` | `YYYY-MM-DD-topic-slug` | Came from an explicit correction; date is when the correction was logged | `correction:2026-04-07-research-methodology` |
| `user` | `YYYY-MM-DD-context-slug` or `explicit-statement` | User directly stated it, not derived from observation or journal | `user:2026-04-10-explicit-statement` |
| `legacy` | `pre-provenance` (only valid ref) | Pre-backfill entry with no traceable evidence. Weaker than any of the above | `legacy:pre-provenance` |

### Slug conventions

- **Topic / description slugs:** lowercase, hyphen-separated, 2–6 words, stripped of punctuation. Keep the key nouns, drop articles and filler.
- **Date prefix:** always `YYYY-MM-DD`, zero-padded. For `journal` refs, the `HHMM` time is the 24-hour time the journal entry was logged.
- **No spaces, no underscores, no camelCase.** Slugs must be stable across tools and grep cleanly.

### Legacy placeholders are weaker than traceable sources

`legacy:pre-provenance` is an honest acknowledgment that an entry predates this scheme and we do not know where it originally came from. It is **not** equivalent to a traceable source. Contradiction detection and health checks should treat legacy-stamped entries as lower-trust than any of the other four types — they may be wrong, outdated, or contradicted by newer evidence. Do not promote new entries with `legacy:*`; it exists only for backfill.

### File-level grandfather header

For canonical files that predate the provenance scheme, a single file-level HTML comment grandfathers all existing entries as `legacy:pre-provenance` without requiring inline stamps on each line. This avoids churning ~100+ lines with uniform, information-free stamps.

Standardized header (place it immediately after the file's `# Title` line):

```markdown
<!-- Provenance: all entries below predate the 2026-04-10 provenance scheme and are grandfathered as `legacy:pre-provenance`. New entries added via `scripts/memory_update.sh` must carry inline `| source: <type>:<ref>` stamps per `CLAUDE.md#Provenance`. -->
```

**Semantics:**
- The header covers existing content only. Any *new* entry added to the file (via `memory_update.sh` or direct edit) MUST carry an inline `| source:` stamp.
- The health check treats the header as valid provenance for pre-existing unstamped entries.
- Over time, as legacy entries are edited, corrected, or replaced, the new versions carry real provenance and the legacy coverage shrinks naturally.
- The header is intentionally dated (2026-04-10) so future readers can see when the scheme was introduced.

### Exemptions

- `observations.md` — its own `[count:N] [first:...] [last:...]` schema is the provenance.
- `corrections.md` — dated per-entry, self-describing.
- `profile.md` — user identity facts rarely have a single traceable origin; provenance is optional but preferred where known.
- `reflections.md` — dated per-entry reflection log (`### YYYY-MM-DD — Topic`); the date header IS the provenance.

### Why

Contradiction detection and the memory health check need to trace a canonical claim back to its evidence. Without provenance, there is no safe way to update or retract a fact when the user's preferences evolve. Shape-validated provenance also lets the health check distinguish "stamped and traceable" from "stamped but unverifiable," which free-text provenance could not.

## Canonical Update Helper

For normal single-fact updates to canonical memory, use `scripts/memory_update.sh` rather than ad hoc edits.

Supported commands:

```bash
scripts/memory_update.sh validate <target-file> --content "<text>"
scripts/memory_update.sh add <target-file> --content "<text>"
scripts/memory_update.sh replace <target-file> --match "<old>" --content "<new>"
scripts/memory_update.sh remove <target-file> --match "<old>"
```

Rules:
- Scope is `self-improving/**` only. The wrapper must never mutate `journal/**`.
- `add` enforces inline provenance for canonical files unless the file is explicitly exempt (`observations.md`, `corrections.md`, `profile.md`).
- `replace` and `remove` must fail unless they find exactly one match.
- Boundary and threat scans are best-effort lint. They catch obvious mistakes; they are not a security boundary.
- The grandfather provenance header only covers pre-existing legacy content. New canonical entries still need inline `| source: <type>:<ref>` stamps.

## Temporal Knowledge Graph

For facts about people, projects, and things that change over time, use the temporal KG at `self-improving/kg.sqlite`. This is a small SQLite-backed triples store inspired by MemPalace's `knowledge_graph.py` — every fact has a `valid_from` date and an optional `ended` date, so historical queries still work even after the fact stops being current.

```bash
scripts/memory_kg.sh init                                       # one-time
scripts/memory_kg.sh add SUBJECT PREDICATE OBJECT \
    --valid-from YYYY-MM-DD --source TYPE:REF
scripts/memory_kg.sh invalidate SUBJECT PREDICATE OBJECT [--ended YYYY-MM-DD]
scripts/memory_kg.sh query ENTITY [--as-of YYYY-MM-DD] [--direction outgoing|incoming|both]
scripts/memory_kg.sh timeline ENTITY
scripts/memory_kg.sh stats
scripts/memory_kg.sh list
```

When to use the KG vs markdown:

- **Markdown canonical memory** (`self-improving/**/*.md`): stable preferences, identity facts, recurring patterns, corrections. Things that don't benefit from a validity window.
- **Temporal KG** (`self-improving/kg.sqlite`): facts that change — who works on what, who's assigned to what, when a preference stopped applying, when a project ended, when someone's role changed. Anything where "what was true in X" matters.

Rules:
- Every KG triple carries a `source:` provenance stamp using the same typed slug grammar as markdown canonical entries.
- `add` fails on duplicate (same subject+predicate+object+valid_from) — use `invalidate` first if the fact is changing.
- `invalidate` fails unless there is exactly one active (not-ended) triple matching. No ambiguous updates.
- Dates must be `YYYY-MM-DD`. The KG is local-time-agnostic — you're recording "when did this become true / stop being true" not "what moment in UTC."
- Re-adding a triple with a NEW `valid_from` after invalidating the old one is the correct way to record a re-occurrence (e.g., someone returning to a project).
