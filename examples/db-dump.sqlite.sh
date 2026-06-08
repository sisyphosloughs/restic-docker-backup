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
# Copies are written to db-dumps/ next to this script (timestamped, rotated by
# RETENTION_DAYS) so they are backed up too.
#
# The generic logic (db-dumps/ creation, retention, timestamps, logging) lives in
# lib/db-dump-lib.sh next to restic-backup.sh. This script only supplies the
# dump_sqlite call(s). It works both standalone (./db-dump.sh) and via
# restic-backup.sh, which passes DB_DUMP_LIB pointing at its bundled library.

set -euo pipefail

# Path to the shared library. restic-backup.sh overrides this via the environment;
# adjust the standalone default below to where you placed restic-docker-backup.
DB_DUMP_LIB="${DB_DUMP_LIB:-/opt/restic-docker-backup/lib/db-dump-lib.sh}"

# How many days each dump is kept (rotation). Set per stack.
# shellcheck disable=SC2034  # read by dump_prepare in the sourced library
RETENTION_DAYS=30

# shellcheck source=/dev/null
source "$DB_DUMP_LIB"

dump_prepare

# --- one line per SQLite database (adjust the path; copy a line to add another) ---
dump_sqlite "$STACK_DIR/data/database.sqlite"
# dump_sqlite "$STACK_DIR/data/another.sqlite"
# ---------------------------------------------------------------------------------
