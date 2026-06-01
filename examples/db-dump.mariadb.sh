#!/usr/bin/env bash
#
# Example db-dump.sh for MariaDB/MySQL.
# Copy into the respective stack directory as "db-dump.sh" and make it
# executable (chmod +x). STACK_NAME is set by restic-backup.sh as an environment
# variable. The dump ends up in the bind mount db-dumps/ (/tmp/dumps inside the
# container).

set -euo pipefail

docker exec "${STACK_NAME}-database-1" \
  /bin/sh -c 'mysqldump -u root -p${MYSQL_ROOT_PASSWORD} --all-databases > /tmp/dumps/dump.sql'
