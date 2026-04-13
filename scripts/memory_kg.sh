#!/usr/bin/env bash
# memory_kg.sh — Temporal knowledge graph CLI over SQLite.
#
# Inspired by MemPalace's knowledge_graph.py (github.com/milla-jovovich/mempalace)
# but scoped to a single triples table with validity windows, for facts about
# people, projects, and things that change over time. Stored at
# self-improving/kg.sqlite alongside the markdown canonical memory.
#
# Usage:
#   scripts/memory_kg.sh init
#   scripts/memory_kg.sh add SUBJECT PREDICATE OBJECT \
#       --valid-from YYYY-MM-DD --source TYPE:REF
#   scripts/memory_kg.sh invalidate SUBJECT PREDICATE OBJECT [--ended YYYY-MM-DD]
#   scripts/memory_kg.sh query ENTITY [--as-of YYYY-MM-DD] [--direction DIR]
#   scripts/memory_kg.sh timeline ENTITY
#   scripts/memory_kg.sh stats
#   scripts/memory_kg.sh list
#
# Environment:
#   MEMORY_KG_DB  path to sqlite db (default: <repo>/self-improving/kg.sqlite)
#
# Provenance types and slug grammars are identical to scripts/memory_update.sh:
#   journal:YYYY-MM.md#YYYY-MM-DD-HHMM-topic-slug
#   observation:YYYY-MM-DD-description-slug
#   correction:YYYY-MM-DD-topic-slug
#   user:YYYY-MM-DD-slug  OR  user:slug
#   legacy:pre-provenance

exec python3 - "$@" <<'PY'
import argparse
import os
import re
import sqlite3
import sys
from datetime import date
from pathlib import Path


# --- Paths --------------------------------------------------------------------

# Note: this script is passed to Python via stdin (heredoc from memory_kg.sh),
# so __file__ may be unset or set to '<stdin>' depending on Python version.
# Do NOT reference __file__ here — walk up from cwd instead, or honor the env
# override for testing.
def resolve_db_path() -> Path:
    override = os.environ.get("MEMORY_KG_DB")
    if override:
        return Path(override).resolve()
    # Find project root by walking up looking for self-improving/
    cur = Path.cwd().resolve()
    for candidate in [cur, *cur.parents]:
        if (candidate / "self-improving").is_dir():
            return (candidate / "self-improving" / "kg.sqlite").resolve()
    fail(
        "could not locate self-improving/ in any parent of "
        f"{cur} — run from inside the Assistant repo or set MEMORY_KG_DB"
    )


# --- Schema -------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS triples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subject TEXT NOT NULL,
    predicate TEXT NOT NULL,
    object TEXT NOT NULL,
    valid_from TEXT NOT NULL,
    ended TEXT,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(subject, predicate, object, valid_from)
);

CREATE INDEX IF NOT EXISTS idx_triples_subject   ON triples(subject);
CREATE INDEX IF NOT EXISTS idx_triples_predicate ON triples(predicate);
CREATE INDEX IF NOT EXISTS idx_triples_object    ON triples(object);
CREATE INDEX IF NOT EXISTS idx_triples_ended     ON triples(ended);
"""


# --- Validation ---------------------------------------------------------------

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# Mirror scripts/memory_update.sh provenance grammar.
PROV_RE = re.compile(r"^(journal|observation|correction|user|legacy):[a-z0-9#.\-]+$")
JOURNAL_RE = re.compile(r"^journal:\d{4}-\d{2}\.md#\d{4}-\d{2}-\d{2}-\d{4}-[a-z0-9-]+$")
OBSERVATION_RE = re.compile(r"^observation:\d{4}-\d{2}-\d{2}-[a-z0-9-]+$")
CORRECTION_RE = re.compile(r"^correction:\d{4}-\d{2}-\d{2}-[a-z0-9-]+$")
USER_RE = re.compile(r"^user:(?:\d{4}-\d{2}-\d{2}-)?[a-z0-9-]+$")
LEGACY_ALLOWED = "legacy:pre-provenance"


def fail(msg: str) -> None:
    print(f"memory_kg: {msg}", file=sys.stderr)
    sys.exit(1)


def validate_date(name: str, value: str) -> None:
    if not DATE_RE.match(value):
        fail(f"{name} must be YYYY-MM-DD, got: {value!r}")


def validate_source(source: str) -> None:
    if not PROV_RE.match(source):
        fail(f"source must match <type>:<ref>: {source!r}")
    if source.startswith("legacy:") and source != LEGACY_ALLOWED:
        fail(f"legacy provenance must be exactly {LEGACY_ALLOWED}, got {source!r}")
    if source.startswith("journal:") and not JOURNAL_RE.match(source):
        fail("journal provenance must match journal:YYYY-MM.md#YYYY-MM-DD-HHMM-topic-slug")
    if source.startswith("observation:") and not OBSERVATION_RE.match(source):
        fail("observation provenance must match observation:YYYY-MM-DD-description-slug")
    if source.startswith("correction:") and not CORRECTION_RE.match(source):
        fail("correction provenance must match correction:YYYY-MM-DD-topic-slug")
    if source.startswith("user:") and not USER_RE.match(source):
        fail("user provenance must match user:YYYY-MM-DD-slug or user:slug")


def validate_nonempty(name: str, value: str) -> None:
    if not value or not value.strip():
        fail(f"{name} must be non-empty")


# --- DB helpers ---------------------------------------------------------------

def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


# --- Commands -----------------------------------------------------------------

def cmd_init(args, db_path: Path) -> int:
    conn = connect(db_path)
    conn.close()
    print(f"init ok: {db_path}")
    return 0


def cmd_add(args, db_path: Path) -> int:
    validate_nonempty("subject", args.subject)
    validate_nonempty("predicate", args.predicate)
    validate_nonempty("object", args.object)
    validate_date("--valid-from", args.valid_from)
    validate_source(args.source)

    conn = connect(db_path)
    try:
        conn.execute(
            "INSERT INTO triples (subject, predicate, object, valid_from, source) "
            "VALUES (?, ?, ?, ?, ?)",
            (args.subject, args.predicate, args.object, args.valid_from, args.source),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        fail(
            "triple already exists with same subject/predicate/object/valid_from "
            "— use invalidate first if the fact changed"
        )
    finally:
        conn.close()
    print(f"add ok: {args.subject} -> {args.predicate} -> {args.object}")
    return 0


def cmd_invalidate(args, db_path: Path) -> int:
    validate_nonempty("subject", args.subject)
    validate_nonempty("predicate", args.predicate)
    validate_nonempty("object", args.object)
    if args.ended:
        validate_date("--ended", args.ended)

    ended = args.ended or date.today().isoformat()

    conn = connect(db_path)
    try:
        matches = conn.execute(
            "SELECT id FROM triples "
            "WHERE subject=? AND predicate=? AND object=? AND ended IS NULL",
            (args.subject, args.predicate, args.object),
        ).fetchall()
        if not matches:
            fail("no active triple matches (invalidate requires exactly one open match)")
        if len(matches) > 1:
            fail(f"multiple active triples match ({len(matches)}) — refusing ambiguous invalidate")

        conn.execute("UPDATE triples SET ended=? WHERE id=?", (ended, matches[0]["id"]))
        conn.commit()
    finally:
        conn.close()
    print(f"invalidate ok: {args.subject} -> {args.predicate} -> {args.object} ended {ended}")
    return 0


def cmd_query(args, db_path: Path) -> int:
    validate_nonempty("entity", args.entity)
    if args.as_of:
        validate_date("--as-of", args.as_of)

    conn = connect(db_path)
    try:
        rows = []
        if args.direction in ("outgoing", "both"):
            rows.extend(_query_direction(conn, args.entity, "subject", args.as_of))
        if args.direction in ("incoming", "both"):
            rows.extend(_query_direction(conn, args.entity, "object", args.as_of))
    finally:
        conn.close()

    if not rows:
        print(f"(no triples for {args.entity})")
        return 0

    for row in rows:
        _print_row(row)
    return 0


def _query_direction(conn, entity, direction_col, as_of):
    """Return rows where `entity` appears in `direction_col` (subject|object).

    `direction_col` is hardcoded internally to the literals "subject" or "object";
    never user-controlled. Safe to f-string into the WHERE clause.
    """
    where = f"{direction_col} = ?"
    params = [entity]
    if as_of is not None:
        # Valid at `as_of` means: valid_from <= as_of AND (ended IS NULL OR ended > as_of)
        where += " AND valid_from <= ? AND (ended IS NULL OR ended > ?)"
        params.extend([as_of, as_of])
    cur = conn.execute(
        f"SELECT subject, predicate, object, valid_from, ended, source "
        f"FROM triples WHERE {where} ORDER BY valid_from ASC, id ASC",
        params,
    )
    return list(cur.fetchall())


def _print_row(row):
    s, p, o, vf, e, src = row["subject"], row["predicate"], row["object"], row["valid_from"], row["ended"], row["source"]
    status = "(current)" if e is None else f"(ended {e})"
    print(f"  {s} -> {p} -> {o}  [from {vf}]  {status}  | source: {src}")


def cmd_timeline(args, db_path: Path) -> int:
    validate_nonempty("entity", args.entity)
    conn = connect(db_path)
    try:
        cur = conn.execute(
            "SELECT subject, predicate, object, valid_from, ended, source "
            "FROM triples WHERE subject = ? OR object = ? "
            "ORDER BY valid_from ASC, id ASC",
            (args.entity, args.entity),
        )
        rows = list(cur.fetchall())
    finally:
        conn.close()

    if not rows:
        print(f"(no timeline entries for {args.entity})")
        return 0

    print(f"Timeline for {args.entity}:")
    for row in rows:
        s, p, o, vf, e, src = row["subject"], row["predicate"], row["object"], row["valid_from"], row["ended"], row["source"]
        if e is None:
            print(f"  {vf} — {s} -> {p} -> {o}  (current)")
        else:
            print(f"  {vf} — {s} -> {p} -> {o}  (ended {e})")
    return 0


def cmd_stats(args, db_path: Path) -> int:
    conn = connect(db_path)
    try:
        total = conn.execute("SELECT COUNT(*) FROM triples").fetchone()[0]
        active = conn.execute("SELECT COUNT(*) FROM triples WHERE ended IS NULL").fetchone()[0]
        ended = total - active

        subjects = conn.execute(
            "SELECT COUNT(DISTINCT subject) FROM triples"
        ).fetchone()[0]
        predicates = conn.execute(
            "SELECT COUNT(DISTINCT predicate) FROM triples"
        ).fetchone()[0]
        objects = conn.execute(
            "SELECT COUNT(DISTINCT object) FROM triples"
        ).fetchone()[0]
    finally:
        conn.close()

    print(f"Database: {db_path}")
    print(f"Total triples:    {total}")
    print(f"  active:         {active}")
    print(f"  ended:          {ended}")
    print(f"Distinct subjects:   {subjects}")
    print(f"Distinct predicates: {predicates}")
    print(f"Distinct objects:    {objects}")
    return 0


def cmd_list(args, db_path: Path) -> int:
    conn = connect(db_path)
    try:
        cur = conn.execute(
            "SELECT subject, predicate, object, valid_from, ended, source "
            "FROM triples ORDER BY valid_from ASC, id ASC"
        )
        rows = list(cur.fetchall())
    finally:
        conn.close()

    if not rows:
        print("(empty)")
        return 0

    for row in rows:
        s, p, o, vf, e, src = row["subject"], row["predicate"], row["object"], row["valid_from"], row["ended"], row["source"]
        status = "(current)" if e is None else f"(ended {e})"
        print(f"  {s} -> {p} -> {o}  [from {vf}]  {status}  | source: {src}")
    return 0


# --- CLI ----------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="memory_kg.sh",
        description="Temporal knowledge graph for self-improving memory.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    p_init = subparsers.add_parser("init", help="create the database and schema")
    p_init.set_defaults(func=cmd_init)

    p_add = subparsers.add_parser("add", help="add a triple with validity window")
    p_add.add_argument("subject")
    p_add.add_argument("predicate")
    p_add.add_argument("object")
    p_add.add_argument("--valid-from", required=True, help="YYYY-MM-DD")
    p_add.add_argument("--source", required=True, help="provenance: <type>:<ref>")
    p_add.set_defaults(func=cmd_add)

    p_inv = subparsers.add_parser("invalidate", help="mark an active triple as ended")
    p_inv.add_argument("subject")
    p_inv.add_argument("predicate")
    p_inv.add_argument("object")
    p_inv.add_argument("--ended", help="YYYY-MM-DD (default: today)")
    p_inv.set_defaults(func=cmd_invalidate)

    p_q = subparsers.add_parser("query", help="query triples about an entity")
    p_q.add_argument("entity")
    p_q.add_argument("--as-of", help="YYYY-MM-DD — only triples valid at that date")
    p_q.add_argument(
        "--direction",
        choices=("outgoing", "incoming", "both"),
        default="both",
    )
    p_q.set_defaults(func=cmd_query)

    p_t = subparsers.add_parser("timeline", help="chronological story of an entity")
    p_t.add_argument("entity")
    p_t.set_defaults(func=cmd_timeline)

    p_s = subparsers.add_parser("stats", help="database overview")
    p_s.set_defaults(func=cmd_stats)

    p_l = subparsers.add_parser("list", help="dump all triples")
    p_l.set_defaults(func=cmd_list)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    db_path = resolve_db_path()
    return args.func(args, db_path)


if __name__ == "__main__":
    sys.exit(main())
PY
