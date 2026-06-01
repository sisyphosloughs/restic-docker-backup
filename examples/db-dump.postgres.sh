#!/usr/bin/env bash
#
# Example db-dump.sh for PostgreSQL.
# Copy into the respective stack directory as "db-dump.sh" and make it
# executable (chmod +x). STACK_NAME is set by restic-backup.sh as an environment
# variable. The dump ends up in the bind mount db-dumps/ (/tmp/dumps inside the
# container).
#
# Single quotes: ${POSTGRES_USER}/${POSTGRES_DB} are expanded INSIDE THE
# CONTAINER, not on the host.

set -euo pipefail

docker exec "${STACK_NAME}-database-1" \
  /bin/sh -c 'pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB} > /tmp/dumps/dump.sql'
