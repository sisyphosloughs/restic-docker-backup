#!/usr/bin/env bash
#
# Example db-dump.sh for MariaDB/MySQL.
# Copy into the respective stack directory as "db-dump.sh" and make it
# executable (chmod +x). STACK_NAME is set by restic-backup.sh as an environment
# variable; the dump ends up in the bind mount db-dumps/ (/tmp/dumps inside the
# container) with a timestamped filename and is rotated by RETENTION_DAYS.
#
# The generic logic (db-dumps/ creation, retention, timestamps, logging) lives in
# lib/db-dump-lib.sh next to restic-backup.sh. This script only supplies the
# DB-specific call. It works both standalone (./db-dump.sh) and via
# restic-backup.sh, which passes DB_DUMP_LIB pointing at its bundled library.

set -euo pipefail

# Path to the shared library. restic-backup.sh overrides this via the environment;
# adjust the standalone default below to where you placed restic-docker-backup.
DB_DUMP_LIB="${DB_DUMP_LIB:-/opt/restic-docker-backup/lib/db-dump-lib.sh}"

# How many days each dump is kept (rotation). Set per stack.
RETENTION_DAYS=30

# shellcheck source=/dev/null
source "$DB_DUMP_LIB"

dump_prepare

# --- the actual dump (adjust the container suffix, e.g. "database-1") ---
dump_mariadb database-1
# -----------------------------------------------------------------------
