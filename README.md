# Assistant

General-purpose personal assistant workspace with persistent memory across Claude Code sessions.

## What This Is

A self-improving memory system for Claude Code that learns about you over time. It tracks your preferences, communication style, corrections, and domain-specific knowledge across sessions so the assistant gets better the more you use it.

## Quick Start

1. Clone this repo
2. Open it in Claude Code (`claude` from the project root)
3. Start chatting. The system will:
   - Build your profile automatically from conversations
   - Track corrections and preferences
   - Maintain domain-specific memory (health, gaming, tech, work, finance)
   - Keep a searchable journal of session recaps

### First-time setup

Initialize the temporal knowledge graph (optional but recommended):

```bash
bash scripts/memory_kg.sh init
```

## Architecture

```
self-improving/           # Your personal memory (builds up over time)
  profile.md              # Who you are
  memory.md               # Cross-topic preferences and patterns
  corrections.md          # Things the assistant got wrong and learned from
  observations.md         # Patterns being confirmed before promotion
  reflections.md          # Self-improvement log
  domains/                # Topic-specific memory
  kg.sqlite               # Temporal knowledge graph

journal/                  # Append-only session history
knowledge/                # External reference material and deliverables
scripts/                  # Hook scripts and memory tools
.claude/rules/            # System reference documentation
```

## How It Works

Three hooks drive the memory system:

- **Preflight** (`session-nudge.sh`): Runs before each message. Manages session state, injects relevant journal context, flags stale buffers.
- **Save pass** (`session-save-hook.sh`): Fires when the assistant tries to stop. Periodically forces a memory checkpoint (corrections, observations, buffer).
- **Pre-compact** (`session-precompact-hook.sh`): Fires before context compaction. Forces a thorough save so nothing is lost.

## Memory Tools

```bash
# Update canonical memory with provenance tracking
bash scripts/memory_update.sh add self-improving/memory.md --content "Prefers dark mode | source: user:2026-01-15-explicit-statement"

# Query the temporal knowledge graph
bash scripts/memory_kg.sh query "ProjectX"
bash scripts/memory_kg.sh timeline "ProjectX"

# Check memory system health
bash scripts/memory_health_check.sh
```

## User Commands

Say these in conversation:

| Command | What it does |
|---------|-------------|
| "What do you know about X?" | Search all memory tiers |
| "Show my profile" | Display your profile |
| "Show my memory" | Display cross-topic memory |
| "Forget X" | Remove something from memory |
| "Remember X" | Log something to memory |
| "Don't log this" | Pause journaling |
| "Resume logging" | Resume journaling |
| "Memory stats" | Run health check |

## Adding New Domains

If a topic area doesn't fit existing domains:

```bash
mkdir -p self-improving/domains/<name>
```

Then create `memory.md` inside with sections for Preferences, Current Setup, Interests, and Patterns.

## License

MIT
