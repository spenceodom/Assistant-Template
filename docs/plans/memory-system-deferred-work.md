# Memory System — Deferred Work

> **Status:** Living roadmap, consolidated 2026-04-10. This is the single source of truth for memory-system work that has not been implemented. Historical execution logs are preserved separately (see "Archived predecessors" at the bottom).
>
> **Not an implementation plan.** Every item below still needs a fresh v1 plan pass before code is written. This doc captures scope, trigger conditions, and rationale — not how-to-build guidance.

## Context — what's already shipped (for orientation only)

- **Phase 1+2 foundation:** gated canonical write path (`scripts/memory_update.sh`), measurement-first health check (`scripts/memory_health_check.sh`), typed provenance with grandfather header, Session Start Protocol checklist + compliance fingerprint. See `2026-04-10-memory-control-plane-phase-1.md` for the full execution log.
- **MemPalace-inspired ports:** Stop hook forced save (`scripts/session-save-hook.sh`), PreCompact hook (`scripts/session-precompact-hook.sh`), temporal knowledge graph (`scripts/memory_kg.sh`, `self-improving/kg.sqlite`), heuristic contradiction candidate scan extension to the health check. See `2026-04-10-mempalace-ports-execution-log.md` for section-by-section notes and code-review findings.

Don't re-plan any of the above. If you think one of those items needs more work, that's a bug/quality item on the shipped thing, not "deferred work" in the sense of this doc.

## Guiding principles

1. **Measurement before enforcement.** Don't set hard thresholds or add blocking hooks until baseline data says the current soft approach is insufficient.
2. **Defer aggressively.** "Deferred" is a valid terminal state. Only build a thing when real evidence says the current approach doesn't work.
3. **Each item needs its own v1 plan.** This doc is intentionally not an implementation contract. Use the `superpowers:writing-plans` skill before starting any of these.
4. **YAGNI holds until broken.** If the Stop hook is working, don't build a background extractor. If the heuristic contradiction scan is working, don't build an LLM fallback. Etc.

## Deferred items

### 1. LLM-assisted contradiction fallback

**What:** If the heuristic contradiction candidate scan (shipped in `memory_health_check.sh`) proves too noisy or misses real contradictions, fall back to an LLM-assisted pass that can reason about semantic conflict rather than keyword overlap.

**Why deferred:** The heuristic shipped and runs clean on the live corpus (0 candidates flagged across ~200 canonical lines). Detection recall is unverified, but there's nothing forcing the escalation yet.

**Trigger to unblock:**
- The heuristic starts flagging persistent false positives that can't be tuned out via stopword/anchor list edits, OR
- A real contradiction is found by hand that the heuristic missed, AND retuning the keyword threshold doesn't catch it.

**Scope when active:** Extend `memory_health_check.sh` (or a sibling script) to call an LLM on pairs flagged as candidates for a second-pass verdict. Consider cost: the health check should still run fast and offline by default — the LLM pass might need to be opt-in via a flag.

### 2. Measurement → enforcement graduation review

**What:** Review accumulated baseline data from `memory_health_check.sh` runs and decide which informational-only signals should become hard failures:
- Char budgets (currently: no hard limit, just "largest file" report)
- Coverage thresholds (currently: % reported, no target)
- Observation backlog size (currently: reported, no threshold)
- Stale observations count (currently: triggers exit 1 per entry, no batch threshold)
- Bypass detection count (currently: informational, no threshold)

**Why deferred:** The Phase 1+2 plan explicitly said "no hard budgets until baseline data." Baseline data only starts accumulating after 2-3 real session cycles.

**Trigger to unblock:** The `graduation` observation in `self-improving/observations.md` hits `count:3`. (As of 2026-04-10 it's at `count:1`. Each session that uses the memory system for substantive work should bump it.)

**Scope when active:**
- Read the last 3 `memory_health_check.sh` outputs (or run it 3 times across distinct sessions).
- Propose concrete thresholds for each category, grounded in the observed numbers.
- Update `scripts/memory_health_check.sh` to apply the new thresholds via `warn()` or a new `fail()` helper.
- Document the chosen numbers and the reasoning in this file (or a dedicated decision record) so the graduation isn't re-litigated.

### 3. PreToolUse blocking hook for direct canonical edits

**What:** A `PreToolUse` hook in `.claude/settings.json` that rejects raw `Edit`/`Write` calls targeting `self-improving/**/*.md` unless the edit came through `scripts/memory_update.sh`.

**Why deferred:** Phase 1+2 explicitly ruled this out of scope — the wrapper is advisory, not gated, until the bypass signal proves agents actually forget to use it. Adding friction pre-emptively would be premature.

**Trigger to unblock:** `memory_health_check.sh`'s bypass-detection section consistently shows agents (including Claude) committing direct edits to `self-improving/` despite the documentation and hook nudges. "Consistently" means a durable pattern across multiple sessions, not one-off refactors that the wrapper genuinely can't express.

**Complications the plan must address:**
- Distinguish legitimate batch maintenance (schema changes, file renames) from single-fact updates. Hard to tell from the tool call alone — needs some heuristic or explicit escape hatch.
- The hook must itself be editable by an agent that needs to escape it for emergency fixes.
- Windows/git-bash execution path needs explicit testing (same category of landmines as the Stop hook).

### 4. Background passive extraction (former Phase 2.5b/c)

**What:** A detached background extractor that reads session transcripts, writes structured candidate observations to a weak `.extraction_candidates.jsonl` artifact (gitignored), and surfaces them in the health check for human review. Phase 2.5c would eventually allow the extractor to write directly into `observations.md` with count-bumping autonomy, but only after 2.5b quality is proven.

**Why deferred:** The Stop hook + PreCompact hook (shipped in MemPalace-ports session) addresses the dormancy problem by running inline — forcing the main agent to do the save pass on cadence — without needing a background process. Phase 2.5a (transcript-access spike) was explicitly cancelled because the Stop hook already validates the transcript-read / checkpointing / MSYS path-handling questions.

**Trigger to unblock:**
- The Stop hook proves insufficient in practice: agents "phone in" the save passes, or the 15-user-message cadence misses important context that should have been captured mid-turn, AND
- Retuning `SAVE_INTERVAL` or rewriting the Stop hook's reason text doesn't fix it.

**Scope when active:**
- Start with 2.5b directly (candidate-artifact writes), NOT 2.5a. The Stop hook already answered 2.5a's core foundation questions (see `2026-04-10-memory-control-plane-phase-2.5-passive-extraction.md` header note for the cancellation rationale).
- Use the Stop hook's transcript-read + checkpointing + `session_id`-keyed state as reference infrastructure.
- Candidate schema should use a stable normalized `key` for dedupe, not fuzzy text matching.
- Review loop must be visible in the Session Start fingerprint (`candidates=pending:N`).
- 2.5c (direct writes to `observations.md`) stays deferred until 2.5b quality is proven AND review friction is the actual bottleneck.

### 5. Provenance backfill on grandfathered content

**What:** The grandfather header pattern covers pre-existing canonical entries with `legacy:pre-provenance`. Some of those entries actually have traceable sources (git blame, recent journal entries, user-confirmed history) that could be backfilled as real typed provenance, shrinking the legacy coverage.

**Why deferred:** Low priority, high effort, and the grandfather header pattern explicitly anticipates this: as content gets naturally edited or corrected over time, new versions carry real provenance and legacy coverage shrinks organically.

**Trigger to unblock:** Legacy-stamped entries become a contradiction-detection quality problem — too many flagged candidates turn out to be "new traceable entry contradicts old legacy entry, but we don't know if the legacy entry was ever right." At that point the legacy coverage is actively hurting and worth backfilling.

**Scope when active:** Pick a file, audit each legacy-stamped entry against git blame + journal history, rewrite with typed provenance where traceable, leave `legacy:pre-provenance` where genuinely untraceable. Keep backfill commits separate from schema changes for cheap rollback.

### 6. Fingerprint verification tooling

**What:** The Session Start Protocol emits a compliance fingerprint (`[session-start profile=ok memory=ok ...]`) on message #1. Currently nothing verifies the fingerprint reflects reality — a willing agent can fake it. An audit tool could scan Claude Code conversation logs and report the fingerprint compliance rate across sessions.

**Why deferred:** Requires a stable data source (Claude Code conversation log format) and a UI to display results. Both are observability concerns, not memory-system concerns. Also the value is limited: the fingerprint was designed to catch *honest forgetting*, not deliberate evasion.

**Trigger to unblock:** The user actively wants to audit memory-system compliance AND Claude Code / `agentchattr` logs are accessible in a parseable format.

**Scope when active:**
- Identify the log source and its stability guarantees.
- Write a scanner that extracts fingerprint lines, validates shape, and reports the rate of sessions that emitted a valid fingerprint.
- Decide whether results go into the health check or a separate report.

### 7. Contradiction scan quality follow-ups

These are quality items on the already-shipped heuristic contradiction scan, not "new work" in the deferred-item sense — but they're the kind of thing that's easy to forget and worth listing.

- **Seeded-corpus recall test.** The scan shipped with zero candidates on the live corpus, which is reassuring but doesn't verify recall. When it's cheap, write a test that plants known contradictions in a fixture and asserts the scan catches them.
- **`MIN_SHARED_KEYWORDS = 3` is an unvalidated tuning knob.** Test (D) in the health-check test suite locks the current value so drift is visible, but the value itself was picked by intuition, not data. Retune if real-world false-positive or false-negative rates become visible.
- **Stopword and anchor-word list drift.** Both lists will need additions as the corpus grows. Expect domain-specific noise words and additional anchor verbs (`favor`, `reject`, `forbids`, `opposes`) to surface in real use.

### 8. Health-check duplicate scanner false-positive fix

**What:** The duplicate/overlap scanner in `scripts/memory_health_check.sh` is matching generic line prefixes (`- **Count:** 1`, `-->`, `- Hosting: ...`) across files rather than semantic content, which produces noisy `[DUPLICATE]` output that has to be mentally filtered.

**Why deferred:** The scanner output is informational-only — it doesn't affect exit code and doesn't gate anything. The signal loss is cosmetic.

**Trigger to unblock:** The noise makes the health check hard to read, OR the scanner misses a real duplicate because the false positives drowned it out.

**Scope when active:**
- Teach the scanner to ignore lines that are structurally boilerplate (schema markers, HTML comments, heading fragments).
- Consider minimum line length or a "signal word count" filter before counting a line as a dedupe candidate.

## What this document is NOT

- **Not an implementation plan.** Each deferred item still needs a v1 plan pass before code.
- **Not a commitment.** Deferred is a valid permanent state. The user decides if and when to activate any item.
- **Not a historical record.** See the archived predecessor docs for execution context and code-review findings from past work.
- **Not Session Start reading.** The pickup order for a cold session lives in `CLAUDE.md` (Session Start Protocol). This doc is only consulted when the user asks "what's left to build on the memory system?"

## Archived predecessor docs

The original project had several execution log and planning documents in `docs/plans/` that are not included in this template. They documented the build-out of the memory system infrastructure that ships with this repo.
