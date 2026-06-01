#!/usr/bin/env bash
#
# restic-backup.sh — automated restic backups for Docker stacks
#
# A single script, with host-specific configuration in separate files
# (config.sh, repos.conf, repo.password) in the same directory.
# Must run with root privileges. See README.md.

set -uo pipefail

# ---------------------------------------------------------------------------
# 1. Initialisation
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

START_EPOCH="$(date +%s)"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

# Global error store
ERRORS=()
# Stacks stopped by the script (for restart / trap)
STOPPED_STACKS=()
# Successfully backed-up targets
SUCCESS_TARGETS=()
# All reachable repos (for forget/prune/check)
REACHABLE_REPOS=()

# ---------------------------------------------------------------------------
# Create the log directory and log file FIRST — so that configuration errors
# also end up in a log file and do not just disappear on stderr.
# Depends only on SCRIPT_DIR, not on config.sh.
# ---------------------------------------------------------------------------

LOG_DIR="$SCRIPT_DIR/logs"
if ! mkdir -p "$LOG_DIR"; then
  echo "FATAL: cannot create log directory: $LOG_DIR" >&2
  exit 1
fi
RUN_TS="$(date +%Y-%m-%dT%H-%M-%S)"
LOG_FILE="$LOG_DIR/backup-$RUN_TS.log"
touch "$LOG_FILE"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  # log <LEVEL> <message...> — format as in the concept: "[INFO]  msg" / "[ERROR] msg"
  local level="$1"; shift
  # Pad the bracket token to width 7 ([INFO] -> "[INFO] ", [ERROR] -> "[ERROR]")
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[${level}]" "$*" \
    | tee -a "$LOG_FILE"
}

log_info()  { log "INFO" "$@"; }
log_error() {
  log "ERROR" "$@"
  ERRORS+=("$*")
}

# Fatal error before/during initialisation: log (file + stdout) and exit.
fatal() {
  log "ERROR" "$@"
  exit 1
}

# ---------------------------------------------------------------------------
# Load configuration (logging is now available)
# ---------------------------------------------------------------------------

CONFIG_FILE="$SCRIPT_DIR/config.sh"
if [[ ! -f "$CONFIG_FILE" ]]; then
  fatal "Configuration file not found: $CONFIG_FILE"
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Check mandatory variables
[[ -n "${STACKS_BASE:-}" ]]          || fatal "STACKS_BASE not set (config.sh)"
[[ -n "${REPOS_FILE:-}" ]]           || fatal "REPOS_FILE not set (config.sh)"
[[ -n "${RESTIC_PASSWORD_FILE:-}" ]] || fatal "RESTIC_PASSWORD_FILE not set (config.sh)"
# Optional variables: take the value from config.sh if set there, otherwise
# fall back to the default. The ":=" only assigns when the variable is unset or
# empty, so a value defined in config.sh always wins.
: "${DOCKER_STOP_TIMEOUT:=20}"
: "${LOG_RETENTION_DAYS:=64}"
# Initialise EXTRA_PATHS as an empty array if not set in config.sh.
# Do not use "${EXTRA_PATHS[@]:-}" — that produces an empty element "".
if [[ -z "${EXTRA_PATHS+x}" ]]; then
  EXTRA_PATHS=()
fi
# Default STOP_STACKS likewise.
if [[ -z "${STOP_STACKS+x}" ]]; then
  STOP_STACKS=()
fi

# Export the optional rclone configuration path as RCLONE_CONFIG, so that both
# the reachability check (rclone lsd) and restic (which starts rclone as a
# subprocess) use the same configuration.
: "${RCLONE_CONFIG_FILE:=}"
if [[ -n "$RCLONE_CONFIG_FILE" ]]; then
  if [[ -r "$RCLONE_CONFIG_FILE" ]]; then
    export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
  else
    log_error "RCLONE_CONFIG_FILE is set but not readable for user '$(id -un)': $RCLONE_CONFIG_FILE"
  fi
fi

# Abort condition: the restic password file must exist
[[ -f "$RESTIC_PASSWORD_FILE" ]] \
  || fatal "restic password file not found: $RESTIC_PASSWORD_FILE"

# ---------------------------------------------------------------------------
# Read and validate the repository list — abort if missing or empty.
# Before registering the trap, so that we exit cleanly here (without stack recovery).
# ---------------------------------------------------------------------------

[[ -f "$REPOS_FILE" ]] || fatal "Repository list not found: $REPOS_FILE"
REPOS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"                 # remove comments
  line="$(echo "$line" | xargs)"     # trim whitespace
  [[ -z "$line" ]] && continue
  REPOS+=("$line")
done < "$REPOS_FILE"

# Abort condition: no repositories defined
[[ "${#REPOS[@]}" -gt 0 ]] || fatal "No repositories configured in $REPOS_FILE"

# ---------------------------------------------------------------------------
# Telegram
# ---------------------------------------------------------------------------

telegram_send() {
  # telegram_send <text>
  local text="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" \
        || "${TELEGRAM_BOT_TOKEN}" == "xxx" || "${TELEGRAM_CHAT_ID}" == "xxx" ]]; then
    log_info "Telegram not configured, notification skipped"
    return 0
  fi
  # Telegram limit: 4096 characters
  text="${text:0:4096}"
  if ! curl -sS --max-time 30 \
      -o /dev/null \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" >/dev/null 2>&1; then
    log "ERROR" "Telegram notification could not be sent"
  fi
}

log_tail() {
  # Last 50 lines of the current log
  tail -n 50 "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

human_duration() {
  # Seconds -> "4m32s"
  local secs="$1"
  printf '%dm%02ds' "$((secs / 60))" "$((secs % 60))"
}

human_bytes() {
  # Bytes -> "234 MB"
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB PB", u, " ");
    i = 1;
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i];
    else printf "%.1f %s", b, u[i];
  }'
}

# restic wrapper with password file
restic_repo() {
  # restic_repo <repo> <args...>
  local repo="$1"; shift
  restic --repo "$repo" --password-file "$RESTIC_PASSWORD_FILE" "$@"
}

check_rclone_config() {
  # Checks — provided that any "rclone:" target is configured at all — whether
  # the user running this script (usually root) can read the rclone
  # configuration. "rclone config" is usually run as a normal user; then the
  # rclone.conf is in that user's home (~/.config/rclone/rclone.conf) and is not
  # visible to root — all rclone targets would be treated as "not reachable".
  local has_rclone=0 repo
  for repo in "${REPOS[@]}"; do
    if [[ "$repo" == rclone:* ]]; then has_rclone=1; break; fi
  done
  [[ "$has_rclone" -eq 0 ]] && return 0

  if ! command -v rclone >/dev/null 2>&1; then
    log_error "rclone targets configured, but 'rclone' is not installed/findable"
    return 0
  fi

  # Determine the configuration path actually used by rclone
  # (takes an exported RCLONE_CONFIG into account).
  local conf_path
  conf_path="$(rclone config file 2>/dev/null | tail -n 1)"

  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    log_info "rclone configuration: using RCLONE_CONFIG_FILE ($RCLONE_CONFIG)"
  fi

  if [[ -n "$conf_path" && -r "$conf_path" ]]; then
    log_info "rclone configuration readable for user '$(id -un)': $conf_path"
  else
    log_error "rclone configuration NOT readable for user '$(id -un)' (${conf_path:-no path determinable}). 'rclone config' was probably run as a different user — as root the rclone.conf is then not visible. Set RCLONE_CONFIG_FILE in config.sh to the absolute path of the rclone.conf (e.g. /home/USER/.config/rclone/rclone.conf) or run 'rclone config' as root. Otherwise all rclone targets are skipped as 'not reachable'."
  fi
}

repo_reachable() {
  # Checks reachability of an rclone target via "rclone lsd".
  # repos are in the form rclone:<remote>:<path>
  local repo="$1"
  if [[ "$repo" == rclone:* ]]; then
    local remote_path="${repo#rclone:}"   # <remote>:<path>
    rclone lsd "${remote_path}" >/dev/null 2>&1
    return $?
  fi
  # Non-rclone repos: no advance check possible, treat as reachable
  return 0
}

# ---------------------------------------------------------------------------
# trap handler
# ---------------------------------------------------------------------------

CLEAN_EXIT=0

cleanup() {
  local rc=$?
  # Only on unexpected abort (not a regular exit via finish())
  if [[ "$CLEAN_EXIT" -eq 1 ]]; then
    return
  fi

  log_error "Unexpected abort (exit code $rc) — bringing stopped stacks back up"

  local stack
  for stack in "${STOPPED_STACKS[@]:-}"; do
    [[ -z "$stack" ]] && continue
    if (cd "$STACKS_BASE/$stack" && docker compose start) >>"$LOG_FILE" 2>&1; then
      log_info "$stack: stack restarted after abort"
    else
      log "ERROR" "$stack: stack could NOT be started after abort (manual intervention needed)"
    fi
  done

  telegram_send "$(printf '❌ [%s] Backup ABORTED\n\n--- Log (last 50 lines) ---\n%s' \
    "$HOSTNAME_SHORT" "$(log_tail)")"
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

log_info "Starting backup run on $HOSTNAME_SHORT"

# Delete old log files
find "$LOG_DIR" -maxdepth 1 -name 'backup-*.log' -type f \
  -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null \
  && log_info "Old logs (>${LOG_RETENTION_DAYS} days) removed"

# Check rclone configuration (only if rclone targets are configured)
check_rclone_config

# Unlock all repos
for repo in "${REPOS[@]}"; do
  if restic_repo "$repo" unlock >>"$LOG_FILE" 2>&1; then
    log_info "$repo: unlock ok"
  else
    log_info "$repo: unlock not possible (maybe not reachable)"
  fi
done

# ---------------------------------------------------------------------------
# Determine the stop/start selection (STACK_DIRS)
# These stacks are dumped, stopped and then started again for a consistent
# backup. This affects ONLY stop/start — regardless of this, the whole of
# STACKS_BASE is always backed up (see backup step), including stacks that are
# already stopped/inactive.
#   STOP_STACKS populated → only these stacks; all others are left untouched.
#   STOP_STACKS empty     → all stacks under STACKS_BASE.
# ---------------------------------------------------------------------------

STACK_DIRS=()
if [[ "${#STOP_STACKS[@]}" -gt 0 ]]; then
  log_info "Stop/start only for: ${STOP_STACKS[*]}"
  for s in "${STOP_STACKS[@]}"; do
    if [[ -d "$STACKS_BASE/$s" ]]; then
      STACK_DIRS+=("$STACKS_BASE/$s")
    else
      log_error "Configured stack (STOP_STACKS) not found, skipped: $STACKS_BASE/$s"
    fi
  done
else
  log_info "STOP_STACKS empty — all stacks under $STACKS_BASE are stopped/started"
  for d in "$STACKS_BASE"/*/; do
    [[ -d "$d" ]] && STACK_DIRS+=("$d")
  done
fi

# ---------------------------------------------------------------------------
# 2. DB dumps
# ---------------------------------------------------------------------------

log_info "--- DB dumps ---"
for stack_dir in "${STACK_DIRS[@]+"${STACK_DIRS[@]}"}"; do
  [[ -d "$stack_dir" ]] || continue
  stack="$(basename "$stack_dir")"
  dump_script="$stack_dir/db-dump.sh"

  if [[ -x "$dump_script" ]]; then
    if STACK_NAME="$stack" "$dump_script" >>"$LOG_FILE" 2>&1; then
      log_info "$stack: DB dump successful"
    else
      log_error "$stack: DB dump failed (exit $?)"
    fi
  fi
done

# ---------------------------------------------------------------------------
# 3. Stop stacks
# ---------------------------------------------------------------------------

log_info "--- Stopping stacks ---"
for stack_dir in "${STACK_DIRS[@]+"${STACK_DIRS[@]}"}"; do
  [[ -d "$stack_dir" ]] || continue
  stack="$(basename "$stack_dir")"
  [[ -f "$stack_dir/docker-compose.yml" || -f "$stack_dir/compose.yml" ]] || continue

  if (cd "$stack_dir" && docker compose stop --timeout "$DOCKER_STOP_TIMEOUT") >>"$LOG_FILE" 2>&1; then
    STOPPED_STACKS+=("$stack")
    log_info "$stack: stack stopped"
  else
    log_error "$stack: stack could not be stopped, will not be backed up"
  fi
done

# ---------------------------------------------------------------------------
# 4. Backup
# ---------------------------------------------------------------------------

log_info "--- Backup ---"
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

for repo in "${REPOS[@]}"; do
  if ! repo_reachable "$repo"; then
    log_error "$repo: target not reachable, skipped"
    continue
  fi
  REACHABLE_REPOS+=("$repo")

  backup_json="$(restic_repo "$repo" backup \
      "$STACKS_BASE" \
      "${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}" \
      --tag "$HOSTNAME_SHORT" \
      --tag "$(date +%Y-%m-%d)" \
      --json 2>>"$LOG_FILE")"
  rc=$?

  # Extract the summary line from the JSON stream
  summary_line="$(printf '%s\n' "$backup_json" | grep '"message_type":"summary"' | tail -n 1)"

  bytes=0
  snapshot="?"
  if [[ -n "$summary_line" ]]; then
    if [[ "$have_jq" -eq 1 ]]; then
      bytes="$(printf '%s' "$summary_line" | jq -r '.total_bytes_processed // 0')"
      snapshot="$(printf '%s' "$summary_line" | jq -r '.snapshot_id // "?"' | cut -c1-8)"
    else
      bytes="$(printf '%s' "$summary_line" | grep -o '"total_bytes_processed":[0-9]*' | grep -o '[0-9]*')"
      snapshot="$(printf '%s' "$summary_line" | grep -o '"snapshot_id":"[a-f0-9]*"' | grep -o '[a-f0-9]\{8\}' | head -n1)"
      bytes="${bytes:-0}"
      snapshot="${snapshot:-?}"
    fi
  fi

  if [[ "$rc" -ne 0 ]]; then
    log_error "$repo: backup failed (exit $rc)"
  elif [[ "${bytes:-0}" -eq 0 ]]; then
    log_error "$repo: 0 bytes backed up"
  else
    log_info "$repo: backup successful ($(human_bytes "$bytes"), snapshot $snapshot)"
    SUCCESS_TARGETS+=("$repo")
  fi
done

# ---------------------------------------------------------------------------
# 5. Start stacks
# ---------------------------------------------------------------------------

log_info "--- Starting stacks ---"
for stack in "${STOPPED_STACKS[@]:-}"; do
  [[ -z "$stack" ]] && continue
  if (cd "$STACKS_BASE/$stack" && docker compose start) >>"$LOG_FILE" 2>&1; then
    log_info "$stack: stack started (wait for health check)"
  else
    log_error "$stack: stack could not be started (manual intervention needed)"
  fi
done
# Stacks are back up — the trap should not touch them again
STOPPED_STACKS=()

# ---------------------------------------------------------------------------
# 6. Forget & Prune
# ---------------------------------------------------------------------------

log_info "--- Forget & Prune ---"
for repo in "${REACHABLE_REPOS[@]:-}"; do
  [[ -z "$repo" ]] && continue
  if restic_repo "$repo" forget \
      --tag "$HOSTNAME_SHORT" \
      --keep-daily 31 \
      --keep-monthly 99 \
      --prune >>"$LOG_FILE" 2>&1; then
    log_info "$repo: forget/prune ok"
  else
    log_error "$repo: forget/prune failed"
  fi
done

# ---------------------------------------------------------------------------
# 7. Repository check (monthly, on the 1st)
# ---------------------------------------------------------------------------

if [[ "$(date +%d)" == "01" ]]; then
  log_info "--- Repository check (monthly) ---"
  for repo in "${REACHABLE_REPOS[@]:-}"; do
    [[ -z "$repo" ]] && continue
    if restic_repo "$repo" check >>"$LOG_FILE" 2>&1; then
      log_info "$repo: check ok"
    else
      log_error "$repo: repository check failed"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 8. Completion
# ---------------------------------------------------------------------------

finish() {
  local end_epoch duration_s duration_h err_count total reachable
  end_epoch="$(date +%s)"
  duration_s="$((end_epoch - START_EPOCH))"
  duration_h="$(human_duration "$duration_s")"
  err_count="${#ERRORS[@]}"
  total="${#REPOS[@]}"
  reachable="${#SUCCESS_TARGETS[@]}"

  log_info "--- Summary ---"
  if [[ "$err_count" -gt 0 ]]; then
    log_info "Recorded errors ($err_count):"
    local e
    for e in "${ERRORS[@]}"; do
      printf '  - %s\n' "$e" | tee -a "$LOG_FILE"
    done
  fi
  log_info "Backup run completed. $err_count errors. Duration: $duration_h"

  # Telegram completion
  local msg
  if [[ "$err_count" -eq 0 ]]; then
    msg="$(printf '✅ [%s] Backup completed\nDuration: %s\nSnapshots: %d/%d targets successful\nErrors: 0' \
      "$HOSTNAME_SHORT" "$duration_h" "$reachable" "$total")"
    telegram_send "$msg"
  else
    msg="$(printf '❌ [%s] Backup completed with errors\nDuration: %s\nSnapshots: %d/%d targets successful\nErrors: %d\n\n--- Log (last 50 lines) ---\n%s' \
      "$HOSTNAME_SHORT" "$duration_h" "$reachable" "$total" "$err_count" "$(log_tail)")"
    telegram_send "$msg"
  fi

  CLEAN_EXIT=1
  if [[ "$err_count" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

finish
