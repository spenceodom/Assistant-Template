# Knowledge Schema

## Purpose

`knowledge/` is the Assistant's place for external source material and durable deliverables.

Use it for:
- notes copied in from outside the chat
- transcripts, screenshots, reference docs, and research
- assistant-generated deliverables worth keeping beyond the thread

Do not use it for:
- user-memory state that belongs in `self-improving/`
- general project documentation that fits better under `docs/`
- every one-off answer from the chat

## Folder Rules

### `raw/`

Put source material here with minimal friction. Examples:
- copied articles
- meeting notes
- transcripts
- screenshots or exported docs
- rough research notes

Treat files in `raw/` as source material. Do not overwrite them with synthesized summaries.

### `outputs/`

Put durable assistant-generated deliverables here only when they are worth revisiting outside the chat. Examples:
- reports
- briefs
- decision memos
- comparison writeups
- polished summaries

Do not use `outputs/` as a dumping ground for routine conversation artifacts.

## Source Traceability

When an output is derived from files in `raw/`, note the source files used. Lightweight traceability is enough:
- mention the raw file names in the document
- or include a short "Sources" section

## Growth Rule

Do not add `knowledge/wiki/` by default.

Add a maintained wiki layer later only if repeated synthesis becomes a recurring need.
