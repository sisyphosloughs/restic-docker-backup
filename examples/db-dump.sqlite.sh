#!/usr/bin/env bash
#
# Example db-dump.sh for SQLite.
# Copy into the respective stack directory as "db-dump.sh" and make it
# executable (chmod +x). STACK_NAME is set by restic-backup.sh as an environment
# variable.
#
# Unlike the MariaDB/Postgres examples, SQLite has NO database server: the
# database is a plain file on the host. The dump therefore runs ENTIRELY OUTSIDE
# the container with the host's sqlite3 binary — no "docker exec". Because
# db-dump.sh runs BEFORE the stack is stopped, the app may still have the DB
# open; the online ".backup" command produces a consistent binary copy anyway.
# Copies are written to db-dumps/ next to this script so they are backed up too.
#
# Multiple databases: just copy a "dump_sqlite ..." line in the section at the
# bottom — one line per SQLite file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMP_DIR="$SCRIPT_DIR/db-dumps"

# How many days each dump is kept. On every run, dumps in DUMP_DIR older than
# this are removed; newer ones (incl. the one just written) are kept.
RETENTION_DAYS=30

# Log in the same format as restic-backup.sh ("<ts> [LEVEL] msg"). No log file is
# written here — restic-backup.sh captures this script's stdout/stderr.
log() {
  local level="$1"; shift
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[${level}]" "$*"
}

# sqlite3 must be available on the host (checked once).
command -v sqlite3 >/dev/null 2>&1 \
  || { log ERROR "${STACK_NAME:-sqlite}: sqlite3 not found on the host"; exit 1; }

# Remove dumps older than RETENTION_DAYS so they do not pile up forever, while
# keeping recent ones. Done ONCE here, before any dump_sqlite call.
mkdir -p "$DUMP_DIR" \
  || { log ERROR "${STACK_NAME:-sqlite}: cannot create dump directory $DUMP_DIR"; exit 1; }
find "$DUMP_DIR" -maxdepth 1 -type f -mtime +"$RETENTION_DAYS" -delete
log INFO "${STACK_NAME:-sqlite}: removed dumps older than ${RETENTION_DAYS} days in $DUMP_DIR"

dump_sqlite() {
  # dump_sqlite <path-to-db-file> — consistent online backup into DUMP_DIR; the
  # target name keeps the original filename plus a timestamp
  # (e.g. database.sqlite -> database-2026-06-07T10-23-00.sqlite).
  local db_file="$1" name ts target
  [[ -f "$db_file" ]] \
    || { log ERROR "${STACK_NAME:-sqlite}: database file not found: $db_file"; exit 1; }
  name="$(basename "$db_file")"
  ts="$(date +%Y-%m-%dT%H-%M-%S)"
  target="$DUMP_DIR/${name%.*}-$ts.${name##*.}"
  if sqlite3 "$db_file" ".backup '$target'"; then
    log INFO "${STACK_NAME:-sqlite}: SQLite backup written: $target"
  else
    log ERROR "${STACK_NAME:-sqlite}: sqlite3 .backup failed for $db_file"; exit 1
  fi
}

# --- one line per SQLite database (adjust the path; copy a line to add another) ---
dump_sqlite "$SCRIPT_DIR/data/database.sqlite"
# dump_sqlite "$SCRIPT_DIR/data/another.sqlite"
# ---------------------------------------------------------------------------------
