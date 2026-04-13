# Memory Health Check

`scripts/memory_health_check.sh` is the single source of truth for the current state of canonical memory. Run it at the start of any substantive memory-system work. This file is lazy-loaded — consult it when you need to interpret health check output or understand what the scanners do.

## What it measures

- **Baseline metrics** — char and line counts per canonical file, plus totals.
- **Provenance coverage** — inline-stamped lines + grandfathered files, reported as a percentage.
- **Observation health** — total observation count and stale observation count.
- **Conflicts & duplicates** — heuristic scan for near-duplicate lines across canonical files (informational only).
- **Contradiction candidates** — heuristic opposing-anchor scan over `profile.md`, `memory.md`, and `domains/*/memory.md` (informational only; see `docs/plans/memory-system-deferred-work.md` § 1 for the deferred LLM fallback).
- **Bypass detection** — commits touching `self-improving/**` that don't reference `memory_update.sh`. Catches honest forgetting, not deliberate evasion.
- **Maintenance canary** — observation backlog size and largest canonical file, visible so neglect is obvious.

## Exit codes

- `0` — clean report, no warnings.
- `1` — warnings (invalid provenance shape, stale observations, neglected files).

Duplicate detection, contradiction candidates, and bypass detection are **informational only** — they do NOT trigger exit 1. The scanners are best-effort lint, not a security boundary.

## Measurement-only phase

The health check is intentionally measurement-first: no hard char budgets, no coverage thresholds, no backlog limits. Baseline data from 2-3 real session cycles will inform graduation to enforcement (see `docs/plans/memory-system-deferred-work.md` § 2). Until then, use the report to build intuition about normal vs abnormal states.
