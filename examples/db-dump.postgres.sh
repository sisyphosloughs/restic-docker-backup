#!/usr/bin/env bash
#
# Example db-dump.sh for PostgreSQL.
# Copy into the respective stack directory as "db-dump.sh" and make it
# executable (chmod +x). The postgres container is auto-detected within this
# stack's compose project, the dump is streamed to db-dumps/ on the host with a
# timestamped filename and is rotated by RETENTION_DAYS. No docker-compose.yml
# change (no bind mount) is required.
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
# shellcheck disable=SC2034  # read by dump_prepare in the sourced library
RETENTION_DAYS=30

# shellcheck source=/dev/null
source "$DB_DUMP_LIB"

dump_prepare

# --- the actual dump --------------------------------------------------------
# Optional overrides — set ONE of these BEFORE the dump_postgres call (only if
# auto-detection or the default credentials are wrong). DB_SERVICE is the compose
# SERVICE name (the key under "services:" in docker-compose.yml), NOT a
# container_name:.
# DB_SERVICE=database              # pin a specific compose service
# DB_CONTAINER=my_postgres         # raw container name/id (bypasses compose)
# DB_USER=u DB_NAME=d DB_PASSWORD=s   # set credentials explicitly

# Auto-detects the postgres container in this compose project (by image name,
# exposed 5432 port, or POSTGRES_* env — so pgvector/pgvecto-rs/postgis/timescale
# variants are found too). Several DBs in this stack? Pin one with DB_SERVICE.
dump_postgres
# ----------------------------------------------------------------------------
