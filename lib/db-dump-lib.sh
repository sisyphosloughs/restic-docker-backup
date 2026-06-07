# shellcheck shell=bash
#
# db-dump-lib.sh — shared helpers for the per-stack db-dump.sh scripts.
#
# This is NOT a standalone program: it is meant to be "source"d from a stack's
# db-dump.sh (see ../examples/ for thin wrappers). It centralises the generic
# parts that used to be copy-pasted into every dump script:
#   - creating the db-dumps/ directory,
#   - rotating/deleting old dumps (retention),
#   - timestamped dump filenames,
#   - logging in restic-backup.sh's format.
#
# The DB-specific bit (which command, which container, user/db) stays in each
# stack's db-dump.sh, which calls the dump_* helpers below.
#
# Context variables — resolved with defaults so a wrapper works BOTH standalone
# (./db-dump.sh) and when launched by restic-backup.sh:
#   STACK_DIR   directory of the calling db-dump.sh (the stack). Derived from the
#               caller's path when not set in the environment.
#   STACK_NAME  used in log messages and as the container name prefix. Defaults
#               to the stack directory name. restic-backup.sh sets this.
#   RETENTION_DAYS  days to keep dumps; set per stack in the wrapper (default 30).
#
# ${BASH_SOURCE[1]} is the file that sourced us (the wrapper), so STACK_DIR is the
# stack directory in both the standalone and the orchestrated case.
: "${STACK_DIR:=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"
: "${STACK_NAME:=$(basename "$STACK_DIR")}"
DUMP_DIR="$STACK_DIR/db-dumps"

# Log in the same format as restic-backup.sh ("<ts> [LEVEL] msg"). No log file is
# written here — restic-backup.sh captures this script's stdout/stderr.
log() {
  local level="$1"; shift
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[${level}]" "$*"
}

_dump_ts() { date +%Y-%m-%dT%H-%M-%S; }

dump_prepare() {
  # Create the dump directory and remove dumps older than RETENTION_DAYS so they
  # do not pile up forever, while keeping recent ones. Call ONCE before the
  # dump_* helpers. RETENTION_DAYS is set per stack in the wrapper (default 30).
  mkdir -p "$DUMP_DIR" \
    || { log ERROR "${STACK_NAME}: cannot create dump directory $DUMP_DIR"; exit 1; }
  find "$DUMP_DIR" -maxdepth 1 -type f -mtime +"${RETENTION_DAYS:=30}" -delete
  log INFO "${STACK_NAME}: removed dumps older than ${RETENTION_DAYS} days in $DUMP_DIR"
}

dump_postgres() {
  # dump_postgres <container-suffix>
  # Dumps via "docker exec ${STACK_NAME}-<suffix>" into the bind mount db-dumps/
  # (/tmp/dumps inside the container) with a timestamped filename.
  # ${POSTGRES_USER}/${POSTGRES_DB} are escaped so they expand INSIDE THE
  # CONTAINER, while the timestamped target path expands here on the host.
  local container="${STACK_NAME}-$1" ts target
  ts="$(_dump_ts)"
  target="/tmp/dumps/dump-${ts}.sql"
  if docker exec "$container" /bin/sh -c \
      "pg_dump -U \${POSTGRES_USER} \${POSTGRES_DB} > '$target'"; then
    log INFO "${STACK_NAME}: PostgreSQL dump written: db-dumps/dump-${ts}.sql"
  else
    log ERROR "${STACK_NAME}: pg_dump failed for container $container"; exit 1
  fi
}

dump_mariadb() {
  # dump_mariadb <container-suffix>
  # Like dump_postgres but with mysqldump. ${MYSQL_ROOT_PASSWORD} expands inside
  # the container; the timestamped target path expands here on the host.
  local container="${STACK_NAME}-$1" ts target
  ts="$(_dump_ts)"
  target="/tmp/dumps/dump-${ts}.sql"
  if docker exec "$container" /bin/sh -c \
      "mysqldump -u root -p\${MYSQL_ROOT_PASSWORD} --all-databases > '$target'"; then
    log INFO "${STACK_NAME}: MariaDB/MySQL dump written: db-dumps/dump-${ts}.sql"
  else
    log ERROR "${STACK_NAME}: mysqldump failed for container $container"; exit 1
  fi
}

dump_sqlite() {
  # dump_sqlite <path-to-db-file>
  # SQLite has no DB server: the database is a plain file on the host, so the
  # dump runs ENTIRELY OUTSIDE the container with the host's sqlite3 binary. The
  # online ".backup" command produces a consistent binary copy even while the app
  # still has the DB open. The target keeps the original filename plus a timestamp
  # (e.g. database.sqlite -> database-2026-06-07T10-23-00.sqlite).
  local db_file="$1" name ts target
  command -v sqlite3 >/dev/null 2>&1 \
    || { log ERROR "${STACK_NAME}: sqlite3 not found on the host"; exit 1; }
  [[ -f "$db_file" ]] \
    || { log ERROR "${STACK_NAME}: database file not found: $db_file"; exit 1; }
  name="$(basename "$db_file")"
  ts="$(_dump_ts)"
  target="$DUMP_DIR/${name%.*}-$ts.${name##*.}"
  if sqlite3 "$db_file" ".backup '$target'"; then
    log INFO "${STACK_NAME}: SQLite backup written: $target"
  else
    log ERROR "${STACK_NAME}: sqlite3 .backup failed for $db_file"; exit 1
  fi
}
