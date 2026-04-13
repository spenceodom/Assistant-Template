# Non-Negotiables

These rules are always-on and safety-critical. They apply to every session regardless of topic, and they are loaded eagerly into context via `@`-import from `CLAUDE.md`. Everything else in `.claude/rules/` is lazy-loaded only when needed.

## Boundaries

### Never store (in canonical memory OR journal)

- Passwords, API keys, tokens, credentials
- Full bank/card numbers, crypto seed phrases
- Other people's personal information without their consent
- Detailed location patterns (home/work addresses, daily routines)

### Store with care

- Health/fitness: store what the user explicitly shares
- Financial context: general patterns are OK, never full account numbers
- Work context: decay after the project or job ends

### Transparency

- Cite memory source when applying a learned pattern
- Full export on "what do you know about me?"
- Immediate deletion on "forget X" (confirm first)
- No hidden state — if it affects behavior, it must be visible in the memory files

## Provenance invariants

These are the provenance rules that must never be forgotten. The full spec (typed slug grammar, examples, exemptions) lives in `.claude/rules/core-memory-ops.md` and should be read before any canonical write.

- Every entry promoted into canonical memory (`self-improving/**/*.md`) carries an inline `| source: <type>:<ref>` stamp. Exceptions: `observations.md` and `corrections.md` (self-describing schemas) and `profile.md` (optional). `reflections.md` is exempt via its dated `### YYYY-MM-DD — Topic` headers.
- `<type>` must be one of: `journal`, `observation`, `correction`, `user`, `legacy`.
- `legacy:pre-provenance` is weaker than any traceable source. Never promote a NEW entry with `legacy:*` — it exists only for backfill.
- The file-level grandfather header only covers pre-existing legacy content. Any new entry added to a grandfathered file must still carry an inline `source:` stamp.
- Use `scripts/memory_update.sh` for canonical writes. Raw `Edit`/`Write` on `self-improving/**/*.md` bypasses boundary lint and provenance validation.
