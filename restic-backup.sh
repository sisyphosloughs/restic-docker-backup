#!/usr/bin/env bash
#
# restic-backup.sh — automated restic backups for Docker stacks
#
# A single script, with host-specific configuration in separate files:
#   global.conf            global switches (binaries, repos, Telegram, …)
#   instances/<name>.conf  one file per backed-up object (BACKUP_PATH, EXCLUDES,
#                          DOCKER, STOP_STACKS)
#   repos.conf             one restic repository URL per line
#   repo.password          restic password (chmod 600, owned by root)
# all in the same directory as this script. Must run with root privileges.
# See README.md.

set -uo pipefail

# ---------------------------------------------------------------------------
# 1. Initialisation
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

START_EPOCH="$(date +%s)"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

# Global error store
ERRORS=()
# Stacks stopped by the script — FULL paths (for restart / trap)
STOPPED_STACKS=()
# Successfully backed-up targets
SUCCESS_TARGETS=()
# All reachable repos (for forget/prune/check)
REACHABLE_REPOS=()

# Aggregated from the instance configurations (see load_instances)
BACKUP_PATHS=()        # all BACKUP_PATHs to back up (one snapshot per repo)
EXCLUDE_PATTERNS=()    # anchored excludes collected from all instances
STACK_DIRS=()          # full paths of stacks to stop/start/dump (DOCKER=true)
ANY_DOCKER=0           # 1 if at least one instance has DOCKER=true

# ---------------------------------------------------------------------------
# Create the log directory and log file FIRST — so that configuration errors
# also end up in a log file and do not just disappear on stderr.
# Depends only on SCRIPT_DIR, not on the configuration.
# ---------------------------------------------------------------------------

LOG_DIR="$SCRIPT_DIR/logs"
if ! mkdir -p "$LOG_DIR"; then
  echo "FATAL: cannot create log directory: $LOG_DIR" >&2
  exit 1
fi
RUN_TS="$(date +%Y-%m-%dT%H-%M-%S)"
LOG_FILE="$LOG_DIR/backup-$RUN_TS.log"
touch "$LOG_FILE"
# The script runs as root, so logs would default to root:root 0600 and be
# unreadable by the normal user (and thus not viewable/syncable). Make them
# world-readable — logs contain paths/snapshot IDs but no secrets.
chmod 644 "$LOG_FILE" 2>/dev/null || true

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
# Small helpers / availability checks
# Defined early so they can run before the rest of the configuration is
# validated (a missing restic should abort before anything else).
# ---------------------------------------------------------------------------

contains() {
  # contains <needle> <haystack...> — returns 0 if <needle> is among the args.
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

instance_docker_enabled() {
  # Whether an instance's DOCKER flag is turned on. Accepts the usual truthy
  # spellings; everything else (incl. unset/empty) is treated as off.
  case "${1:-false}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

any_docker_enabled() {
  # Whether the optional Docker stack orchestration (DB dumps + stop/start) runs
  # at all — true as soon as at least one instance has DOCKER=true. Replaces the
  # former global DOCKER_STACKS_ENABLED switch.
  [[ "${ANY_DOCKER:-0}" -eq 1 ]]
}

dry_run_enabled() {
  # When enabled, restic runs the backup with --dry-run --verbose=2: nothing is
  # written, and the per-file listing of what *would* be backed up goes to the
  # log. The repository-modifying steps (forget/prune) and the monthly check
  # are skipped. Controlled by DRY_RUN in global.conf; default off.
  case "${DRY_RUN:-false}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

has_rclone_targets() {
  # Returns 0 if at least one "rclone:" target is configured in REPOS_FILE.
  # Reads the file directly so it also works before REPOS has been parsed.
  [[ -n "${REPOS_FILE:-}" && -f "$REPOS_FILE" ]] || return 1
  grep -Eq '^[[:space:]]*rclone:' "$REPOS_FILE"
}

check_binaries() {
  # Check and log the availability of the required external programs at the very
  # start, so missing/mislocated binaries are obvious in the log instead of
  # surfacing as cryptic failures later. Honours the optional RESTIC_BIN /
  # RCLONE_BIN paths from global.conf.
  log_info "--- Checking programs ---"
  local p

  # restic (mandatory) — abort if not found.
  if p="$(command -v "$RESTIC_BIN" 2>/dev/null)"; then
    log_info "restic found: $p ($("$RESTIC_BIN" version 2>/dev/null | head -n1))"
  else
    fatal "restic not found: '$RESTIC_BIN'. Set RESTIC_BIN in global.conf to the absolute path (e.g. /volume1/opt/bin/restic)."
  fi

  # docker + Compose V2 plugin — only relevant when an instance uses DOCKER.
  if any_docker_enabled; then
    if p="$(command -v docker 2>/dev/null)"; then
      if docker compose version >/dev/null 2>&1; then
        log_info "docker found: $p (Compose V2 plugin available)"
      else
        log_error "docker found ($p), but the Compose V2 plugin ('docker compose') is not available — stacks cannot be stopped/started"
      fi
    else
      log_error "docker not found — stacks cannot be stopped/started"
    fi
  else
    log_info "No instance has DOCKER=true — skipping docker/compose check"
  fi

  # rclone (only if rclone targets are configured).
  if has_rclone_targets; then
    if p="$(command -v "$RCLONE_BIN" 2>/dev/null)"; then
      log_info "rclone found: $p ($("$RCLONE_BIN" version 2>/dev/null | head -n1)); restic uses it via -o rclone.program"
    else
      log_error "rclone targets configured, but rclone not found: '$RCLONE_BIN'. Set RCLONE_BIN in global.conf to the absolute path (e.g. /volume1/opt/bin/rclone)."
    fi
  fi

  # curl (only if Telegram is configured).
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && "${TELEGRAM_BOT_TOKEN}" != "xxx" \
        && -n "${TELEGRAM_CHAT_ID:-}" && "${TELEGRAM_CHAT_ID}" != "xxx" ]]; then
    if p="$(command -v curl 2>/dev/null)"; then
      log_info "curl found: $p (Telegram notifications enabled)"
    else
      log_error "Telegram is configured, but curl not found — notifications will not be sent"
    fi
  fi

  # jq (optional — a grep fallback is used otherwise).
  if p="$(command -v jq 2>/dev/null)"; then
    log_info "jq found: $p"
  else
    log_info "jq not found — using grep fallback for restic JSON output"
  fi
}

load_instances() {
  # Collect all instance configurations from INSTANCES_DIR — one *.conf file per
  # backed-up object. Each file may set:
  #   BACKUP_PATH   (required) directory to back up
  #   EXCLUDES      (array)    restic exclude patterns for this object
  #   DOCKER        (bool)     run db-dump.sh + stop/start (BACKUP_PATH is then
  #                            treated as a base dir whose sub-directories are
  #                            stacks)
  #   STOP_STACKS   (array)    sub-directory names to stop/start (empty = all);
  #                            only relevant when DOCKER=true
  #
  # NOTE: the per-object path variable is BACKUP_PATH, NOT PATH — using the name
  # "PATH" would clobber the shell's executable search path and break the run.
  #
  # Files are sourced one at a time with the four variables reset beforehand, so
  # a value from one file never leaks into the next. Templates (*.example) are
  # skipped (they do not end in .conf anyway).
  #
  # Aggregated into the globals used by the rest of the script:
  #   BACKUP_PATHS[]     all valid BACKUP_PATHs (backed up together → one
  #                      snapshot per repo)
  #   EXCLUDE_PATTERNS[] union of all EXCLUDES, deduplicated (restic applies
  #                      --exclude across every path of the single backup call)
  #   STACK_DIRS[]       full paths of the stacks to stop/start/dump across all
  #                      DOCKER=true instances
  #   ANY_DOCKER         1 if at least one instance has DOCKER=true
  local conf name pat base s d found=0

  [[ -d "$INSTANCES_DIR" ]] || fatal "Instances directory not found: $INSTANCES_DIR"

  for conf in "$INSTANCES_DIR"/*.conf; do
    [[ -e "$conf" ]] || continue                 # no *.conf present at all
    case "$conf" in *.example) continue ;; esac  # skip templates (defensive)

    # Reset per-instance variables so nothing leaks between files.
    local BACKUP_PATH="" DOCKER="false"
    local EXCLUDES=() STOP_STACKS=()

    # shellcheck source=/dev/null
    source "$conf"
    name="$(basename "${conf%.conf}")"
    found=$((found + 1))

    if [[ -z "$BACKUP_PATH" ]]; then
      log_error "Instance '$name' ($conf): BACKUP_PATH not set — instance skipped"
      continue
    fi
    if [[ ! -d "$BACKUP_PATH" ]]; then
      log_error "Instance '$name': BACKUP_PATH does not exist, instance skipped: $BACKUP_PATH"
      continue
    fi

    BACKUP_PATHS+=("$BACKUP_PATH")

    # Anchor this instance's excludes to its BACKUP_PATH so they apply ONLY under
    # that path. restic's --exclude is otherwise global across every path of the
    # single backup call, so an unanchored basename pattern (e.g. @eaDir) would
    # match under all instances. A pattern that already starts with "/" is taken
    # verbatim (the user anchors it themselves — the escape hatch). A relative /
    # basename pattern <pat> is emitted in two anchored forms so it matches at
    # every depth under the base:
    #   <base>/<pat>     directly in the base directory
    #   <base>/**/<pat>  at any depth below it
    # The explicit <base>/<pat> is a safety net in case restic's ** does not
    # match zero directories. Patterns are deduplicated.
    base="${BACKUP_PATH%/}"
    for pat in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
      [[ -z "$pat" ]] && continue
      if [[ "$pat" == /* ]]; then
        contains "$pat" "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}" \
          || EXCLUDE_PATTERNS+=("$pat")
      else
        contains "$base/$pat" "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}" \
          || EXCLUDE_PATTERNS+=("$base/$pat")
        contains "$base/**/$pat" "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}" \
          || EXCLUDE_PATTERNS+=("$base/**/$pat")
      fi
    done

    if instance_docker_enabled "$DOCKER"; then
      ANY_DOCKER=1
      if [[ "${#STOP_STACKS[@]}" -gt 0 ]]; then
        log_info "Instance '$name' (DOCKER): base $BACKUP_PATH — stop/start only: ${STOP_STACKS[*]}"
        for s in "${STOP_STACKS[@]}"; do
          [[ -z "$s" ]] && continue
          if [[ -d "$BACKUP_PATH/$s" ]]; then
            STACK_DIRS+=("$BACKUP_PATH/$s")
          else
            log_error "Instance '$name': configured stack (STOP_STACKS) not found, skipped: $BACKUP_PATH/$s"
          fi
        done
      else
        log_info "Instance '$name' (DOCKER): base $BACKUP_PATH — STOP_STACKS empty, all sub-stacks stopped/started"
        for d in "$BACKUP_PATH"/*/; do
          [[ -d "$d" ]] && STACK_DIRS+=("${d%/}")
        done
      fi
    else
      log_info "Instance '$name': $BACKUP_PATH (DOCKER=false)"
    fi
  done

  [[ "$found" -gt 0 ]] \
    || fatal "No instance configurations (*.conf) found in $INSTANCES_DIR"
  [[ "${#BACKUP_PATHS[@]}" -gt 0 ]] \
    || fatal "No valid instances (with an existing BACKUP_PATH) in $INSTANCES_DIR"
}

# ---------------------------------------------------------------------------
# Load configuration (logging is now available)
# ---------------------------------------------------------------------------

GLOBAL_CONF="$SCRIPT_DIR/global.conf"
if [[ ! -f "$GLOBAL_CONF" ]]; then
  fatal "Global configuration file not found: $GLOBAL_CONF"
fi
# shellcheck source=/dev/null
source "$GLOBAL_CONF"

# Optional absolute paths to the restic / rclone binaries. Empty / unset = use
# whatever is found in PATH. On some hosts (e.g. a NAS) the binaries live in a
# non-standard location such as /volume1/opt/bin that is not in the (cron) PATH
# — set the absolute path there. restic launches rclone as a subprocess; it is
# told which binary to use via "-o rclone.program=$RCLONE_BIN" (see
# restic_repo), so rclone does NOT need to be in PATH either.
# Set before check_binaries so the availability check honours these paths.
: "${RESTIC_BIN:=restic}"
: "${RCLONE_BIN:=rclone}"

# Check mandatory global variables
[[ -n "${REPOS_FILE:-}" ]]           || fatal "REPOS_FILE not set (global.conf)"
[[ -n "${RESTIC_PASSWORD_FILE:-}" ]] || fatal "RESTIC_PASSWORD_FILE not set (global.conf)"
# Optional variables: take the value from global.conf if set there, otherwise
# fall back to the default. The ":=" only assigns when the variable is unset or
# empty, so a value defined in global.conf always wins.
: "${DOCKER_STOP_TIMEOUT:=20}"
: "${LOG_RETENTION_DAYS:=64}"
: "${DRY_RUN:=false}"

# Collect all instance configurations (sets BACKUP_PATHS, EXCLUDE_PATTERNS,
# STACK_DIRS and ANY_DOCKER). Done before check_binaries so the docker/compose
# check only runs when at least one instance actually uses DOCKER.
INSTANCES_DIR="$SCRIPT_DIR/instances"
load_instances

# Check that the required programs are available (honours RESTIC_BIN/RCLONE_BIN
# and ANY_DOCKER). A missing restic aborts here.
check_binaries

# Optional rclone configuration path. rclone does NOT reliably pick up the
# config from the RCLONE_CONFIG environment variable on every host (on this NAS
# it still falls back to /root/.config/rclone/rclone.conf and fails). So the
# config is passed EXPLICITLY via "--config" everywhere it is used:
#   - direct rclone calls here (reachability check, "rclone config file") use
#     RCLONE_CONFIG_ARGS below;
#   - restic passes it to its rclone subprocess via rclone.args (see restic_repo).
# RCLONE_CONFIG is still exported as a harmless best-effort fallback for any
# rclone invocation not covered above.
RCLONE_CONFIG_ARGS=()
: "${RCLONE_CONFIG_FILE:=}"
if [[ -n "$RCLONE_CONFIG_FILE" ]]; then
  if [[ -r "$RCLONE_CONFIG_FILE" ]]; then
    export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
    RCLONE_CONFIG_ARGS=(--config "$RCLONE_CONFIG_FILE")
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
  # For rclone targets, tell restic which rclone binary to launch as its
  # subprocess (RCLONE_BIN); this allows a fixed/absolute path without rclone
  # being in PATH. For non-rclone repos these options are irrelevant and omitted.
  #
  # The rclone.program option carries NO arguments, and rclone does not reliably
  # honour RCLONE_CONFIG from the environment on every host (e.g. this NAS, where
  # rclone still falls back to /root/.config/rclone/rclone.conf). So the config
  # is passed EXPLICITLY via "--config" in rclone.args. rclone.args REPLACES
  # restic's built-in defaults, so they are reproduced here verbatim:
  #   restic >= 0.12 default = "serve restic --stdio --b2-hard-delete"
  # Keep that in sync if restic ever changes it. (A config path with spaces is
  # not supported, since restic splits rclone.args on spaces.)
  local repo="$1"; shift
  local opts=()
  if [[ "$repo" == rclone:* ]]; then
    opts+=(-o "rclone.program=$RCLONE_BIN")
    if [[ -n "${RCLONE_CONFIG_FILE:-}" ]]; then
      opts+=(-o "rclone.args=serve restic --stdio --b2-hard-delete --config $RCLONE_CONFIG_FILE")
    fi
  fi
  "$RESTIC_BIN" "${opts[@]+"${opts[@]}"}" --repo "$repo" \
    --password-file "$RESTIC_PASSWORD_FILE" "$@"
}

check_rclone_config() {
  # Checks — provided that any "rclone:" target is configured at all — whether
  # the user running this script (usually root) can read the rclone
  # configuration. "rclone config" is usually run as a normal user; then the
  # rclone.conf is in that user's home (~/.config/rclone/rclone.conf) and is not
  # visible to root — all rclone targets would be treated as "not reachable".
  has_rclone_targets || return 0

  # rclone presence is already reported by check_binaries; nothing to check here
  # if it is missing.
  command -v "$RCLONE_BIN" >/dev/null 2>&1 || return 0

  # Determine the configuration path actually used by rclone (takes the explicit
  # --config / exported RCLONE_CONFIG into account).
  local conf_path
  conf_path="$("$RCLONE_BIN" "${RCLONE_CONFIG_ARGS[@]+"${RCLONE_CONFIG_ARGS[@]}"}" config file 2>/dev/null | tail -n 1)"

  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    log_info "rclone configuration: using RCLONE_CONFIG_FILE ($RCLONE_CONFIG)"
  fi

  if [[ -n "$conf_path" && -r "$conf_path" ]]; then
    log_info "rclone configuration readable for user '$(id -un)': $conf_path"
  else
    log_error "rclone configuration NOT readable for user '$(id -un)' (${conf_path:-no path determinable}). 'rclone config' was probably run as a different user — as root the rclone.conf is then not visible. Set RCLONE_CONFIG_FILE in global.conf to the absolute path of the rclone.conf (e.g. /home/USER/.config/rclone/rclone.conf) or run 'rclone config' as root. Otherwise all rclone targets are skipped as 'not reachable'."
  fi
}

repo_reachable() {
  # Probes an rclone target via "rclone lsd". repos are in the form
  # rclone:<remote>:<path>. Sets two globals for the caller:
  #   REPO_PROBE_STATUS       -> "reachable" | "repo-missing" | "unreachable"
  #   REPO_UNREACHABLE_REASON -> rclone command + exit code + output on failure,
  #                              so the caller can log *why* instead of a bare
  #                              "not reachable".
  # Returns 0 only when the target is reachable AND the repo path is present.
  local repo="$1"
  REPO_PROBE_STATUS="reachable"
  REPO_UNREACHABLE_REASON=""
  if [[ "$repo" == rclone:* ]]; then
    local remote_path="${repo#rclone:}"   # <remote>:<path>
    local out rc
    out="$("$RCLONE_BIN" "${RCLONE_CONFIG_ARGS[@]+"${RCLONE_CONFIG_ARGS[@]}"}" lsd "${remote_path}" 2>&1)"
    rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    # rclone exit 3 = "directory not found": the remote was reached and answered,
    # the repository path simply does not exist yet (e.g. not "restic init"ed).
    # Flag that distinctly so it is not mislabelled as "target not reachable".
    if [[ "$rc" -eq 3 ]]; then
      REPO_PROBE_STATUS="repo-missing"
    else
      REPO_PROBE_STATUS="unreachable"
    fi
    REPO_UNREACHABLE_REASON="rclone lsd ${remote_path} (config: ${RCLONE_CONFIG_FILE:-rclone default}) exited $rc"
    [[ -n "$out" ]] && REPO_UNREACHABLE_REASON+=$'\n'"$out"
    return 1
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

  local stack_dir stack
  for stack_dir in "${STOPPED_STACKS[@]:-}"; do
    [[ -z "$stack_dir" ]] && continue
    stack="$(basename "$stack_dir")"
    if (cd "$stack_dir" && docker compose start) >>"$LOG_FILE" 2>&1; then
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
# 2.–3. Docker stack management (optional — runs only if at least one instance
# has DOCKER=true). STACK_DIRS was assembled while loading the instances: for
# every DOCKER=true instance it holds the stack directories to stop/start (its
# STOP_STACKS selection, or all sub-directories of its BACKUP_PATH when empty).
# This affects ONLY stop/start/dumps — regardless of it, every instance's
# BACKUP_PATH is always backed up in full (see backup step), including stacks
# that are already stopped/inactive.
# When no instance uses DOCKER (default), this whole part is skipped and the
# data is backed up while the containers keep running.
# ---------------------------------------------------------------------------

if ! any_docker_enabled; then
  log_info "No instance has DOCKER=true — no DB dumps, no stop/start; data is backed up while containers keep running"
else
  # DB dumps
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

  # Stop stacks
  log_info "--- Stopping stacks ---"
  for stack_dir in "${STACK_DIRS[@]+"${STACK_DIRS[@]}"}"; do
    [[ -d "$stack_dir" ]] || continue
    stack="$(basename "$stack_dir")"
    [[ -f "$stack_dir/docker-compose.yml" || -f "$stack_dir/compose.yml" ]] || continue

    if (cd "$stack_dir" && docker compose stop --timeout "$DOCKER_STOP_TIMEOUT") >>"$LOG_FILE" 2>&1; then
      STOPPED_STACKS+=("$stack_dir")
      log_info "$stack: stack stopped"
    else
      log_error "$stack: stack could not be stopped, will not be backed up"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 4. Backup
# ---------------------------------------------------------------------------

log_info "--- Backup ---"
if dry_run_enabled; then
  log_info "DRY RUN enabled (DRY_RUN) — restic runs with --dry-run --verbose=2; nothing is written, forget/prune and the monthly check are skipped"
fi
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# Build the restic exclude arguments from EXCLUDE_PATTERNS. All BACKUP_PATHs are
# backed up together in one call per repo (one snapshot per repo). Relative
# patterns have already been anchored to their instance's BACKUP_PATH by
# load_instances, so each exclude applies only under its own path. Patterns with
# a leading "/" were taken verbatim (user-anchored).
EXCLUDE_ARGS=()
for pat in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
  EXCLUDE_ARGS+=(--exclude "$pat")
done
log_info "Backup paths: ${BACKUP_PATHS[*]}"
if [[ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]]; then
  log_info "Excludes: ${EXCLUDE_PATTERNS[*]}"
fi

for repo in "${REPOS[@]}"; do
  if ! repo_reachable "$repo"; then
    if [[ "${REPO_PROBE_STATUS:-}" == "repo-missing" ]]; then
      log_error "$repo: repository path not found on the remote — the target IS reachable, but the repo does not exist yet. Initialise it once with 'restic ... init' (see README), then re-run. Skipped."
    else
      log_error "$repo: target not reachable, skipped"
    fi
    if [[ -n "${REPO_UNREACHABLE_REASON:-}" ]]; then
      # Surface the rclone diagnostics (command, exit code, error output) so the
      # user can see *why* — indented under the error, to both log and stdout.
      while IFS= read -r reason_line; do
        printf '        %s\n' "$reason_line" | tee -a "$LOG_FILE"
      done <<< "$REPO_UNREACHABLE_REASON"
    fi
    continue
  fi
  REACHABLE_REPOS+=("$repo")

  if dry_run_enabled; then
    # Dry run: no snapshot is created. The human-readable per-file verbose output
    # (what restic *would* back up) is sent to BOTH the terminal and the log via
    # tee — so it is visible live on an interactive run, not only in the file.
    # PIPESTATUS[0] keeps restic's exit code (not tee's).
    log_info "$repo: dry-run — listing what would be backed up (output below + in log)"
    restic_repo "$repo" backup \
        "${BACKUP_PATHS[@]}" \
        "${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"}" \
        --tag "$HOSTNAME_SHORT" \
        --tag "$(date +%Y-%m-%d)" \
        --dry-run --verbose=2 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
    if [[ "$rc" -ne 0 ]]; then
      log_error "$repo: dry-run failed (exit $rc)"
    else
      log_info "$repo: dry-run ok"
      SUCCESS_TARGETS+=("$repo")
    fi
    continue
  fi

  backup_json="$(restic_repo "$repo" backup \
      "${BACKUP_PATHS[@]}" \
      "${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"}" \
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
# 5. Start stacks (only if at least one instance uses DOCKER)
# ---------------------------------------------------------------------------

if any_docker_enabled; then
  log_info "--- Starting stacks ---"
  for stack_dir in "${STOPPED_STACKS[@]:-}"; do
    [[ -z "$stack_dir" ]] && continue
    stack="$(basename "$stack_dir")"
    if (cd "$stack_dir" && docker compose start) >>"$LOG_FILE" 2>&1; then
      log_info "$stack: stack started (wait for health check)"
    else
      log_error "$stack: stack could not be started (manual intervention needed)"
    fi
  done
  # Stacks are back up — the trap should not touch them again
  STOPPED_STACKS=()
fi

# ---------------------------------------------------------------------------
# 6. Forget & Prune
# ---------------------------------------------------------------------------

log_info "--- Forget & Prune ---"
if dry_run_enabled; then
  log_info "Skipped (dry run) — no snapshots are removed"
else
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
fi

# ---------------------------------------------------------------------------
# 7. Repository check (monthly, on the 1st)
# ---------------------------------------------------------------------------

if [[ "$(date +%d)" == "01" ]]; then
  if dry_run_enabled; then
    log_info "--- Repository check (monthly) --- skipped (dry run)"
  else
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
fi

# ---------------------------------------------------------------------------
# 8. Completion
# ---------------------------------------------------------------------------

finish() {
  local end_epoch duration_s duration_h err_count total reachable dry_tag=""
  end_epoch="$(date +%s)"
  duration_s="$((end_epoch - START_EPOCH))"
  duration_h="$(human_duration "$duration_s")"
  err_count="${#ERRORS[@]}"
  total="${#REPOS[@]}"
  reachable="${#SUCCESS_TARGETS[@]}"
  dry_run_enabled && dry_tag=" [DRY RUN]"

  log_info "--- Summary ---"
  if [[ "$err_count" -gt 0 ]]; then
    log_info "Recorded errors ($err_count):"
    local e
    for e in "${ERRORS[@]}"; do
      printf '  - %s\n' "$e" | tee -a "$LOG_FILE"
    done
  fi
  log_info "Backup run completed${dry_tag}. $err_count errors. Duration: $duration_h"

  # Telegram completion
  local msg
  if [[ "$err_count" -eq 0 ]]; then
    msg="$(printf '✅ [%s]%s Backup completed\nDuration: %s\nSnapshots: %d/%d targets successful\nErrors: 0' \
      "$HOSTNAME_SHORT" "$dry_tag" "$duration_h" "$reachable" "$total")"
    telegram_send "$msg"
  else
    msg="$(printf '❌ [%s]%s Backup completed with errors\nDuration: %s\nSnapshots: %d/%d targets successful\nErrors: %d\n\n--- Log (last 50 lines) ---\n%s' \
      "$HOSTNAME_SHORT" "$dry_tag" "$duration_h" "$reachable" "$total" "$err_count" "$(log_tail)")"
    telegram_send "$msg"
  fi

  CLEAN_EXIT=1
  if [[ "$err_count" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

finish
