# restic-docker-backup

Automated restic backups for Docker stacks on various hosts (e.g. a Linux VPS
or a NAS). A single script, with host-specific configuration in separate files
in the same directory. Any backend supported by restic can serve as the backup
target (local, SFTP, S3, REST, …); rclone is optional and only needed for
`rclone:` targets.

## Files

```
<location>/
├── restic-backup.sh        # the script (identical on all hosts)
├── config.sh               # host-specific configuration  (from config.sh.example)
├── repos.conf              # host-specific repository list (from repos.conf.example)
├── repo.password           # restic password (chmod 600, owned by root)
├── examples/               # example DB dump scripts
└── logs/                   # one log file per run (auto-rotated), created by the script
```

The script determines its own location at runtime; all paths are derived from
`SCRIPT_DIR`. The location is freely choosable.

## Setup

1. **Clone the repository / place the files** anywhere you like.

2. **Create the configuration** (host-specific):
   ```bash
   cp config.sh.example config.sh
   cp repos.conf.example repos.conf
   $EDITOR config.sh repos.conf
   ```
3. **Store the restic password**:
   ```bash
   sudo sh -c 'echo "YOUR-RESTIC-PASSWORD" > repo.password'
   sudo chown root:root repo.password
   sudo chmod 600 repo.password
   ```

4. **Configure rclone** (only if `rclone:` targets are used):
   ```bash
   rclone config        # create remotes, e.g. pcloud, s3, b2
   ```
   This step is not needed for local, SFTP, S3 or REST targets.

   > **Important:** The backup script runs as **root**. If `rclone config` is
   > run as a normal user, the `rclone.conf` ends up in that user's home
   > (`~/.config/rclone/rclone.conf`) and is **not readable** by root — all
   > `rclone:` targets are then treated as "not reachable" and skipped.
   > Remedy: either run `rclone config` as root straight away
   > (`sudo rclone config`), **or** set `RCLONE_CONFIG_FILE` in `config.sh` to
   > the absolute path of the `rclone.conf`. The script checks this at startup
   > and writes a corresponding note to the log.

5. **Initialise the repositories** (manually, once per target):
   ```bash
   # local target
   restic --repo /mnt/backup/restic-<host> \
     --password-file ./repo.password init

   # or via rclone
   restic --repo rclone:pcloud:restic-<host> \
     --password-file ./repo.password init
   ```

6. **Set up DB dumps** (optional, per stack):
   Place an executable `db-dump.sh` in each stack directory. Templates are in
   [examples/](examples/). `STACK_NAME` is set by the backup script as an
   environment variable. The dump must be written to the bind mount `db-dumps/`
   (`/tmp/dumps` inside the container) so that it is backed up as well.

## Which stacks are stopped? (`STOP_STACKS`)

**The whole of `STACKS_BASE` is always backed up** — including stacks that are
already stopped or permanently inactive. The `STOP_STACKS` array solely controls
which stacks are **stopped and then started again** for a consistent backup
(and for which `db-dump.sh` runs):

- **`STOP_STACKS` empty** → all stacks under `STACKS_BASE` are stopped and
  started again.
- **`STOP_STACKS` populated** (directory names under `STACKS_BASE`) → only these
  stacks are stopped/started. All others are left untouched — they are neither
  stopped nor (re)started, but are still backed up.

```bash
# config.sh — stop/start only these running stacks for the backup
STOP_STACKS=(
  "solidtime"
  "nextcloud"
)
```

Typical use case: list running stacks with open DB files here so that they are
backed up consistently; do **not** list stacks that are already stopped, so
that they are not started by mistake — they are backed up regardless.

A listed but non-existent stack is logged as an error and skipped (the run does
not abort).

## Running

The script must run with root privileges so that all files in the Docker stack
directories are readable:

```bash
sudo ./restic-backup.sh
```

Exit code: `0` on success, `1` on one or more errors.

## Workflow

1. Initialisation, open log file, delete old logs, unlock repos
2. Run DB dumps per stack
3. Stop stacks (`docker compose stop`)
4. Back up to each reachable repository target
5. Start stacks again (`docker compose start`)
6. `restic forget --prune` (keep-daily 31, keep-monthly 99)
7. `restic check` — monthly only (on the 1st)
8. Summary to the log + Telegram notification

If the script is aborted unexpectedly (`INT`/`TERM`/error), a trap handler
brings the stopped stacks back up and sends a Telegram warning.

> **Note:** `docker compose start` returns as soon as the containers are
> running, not as soon as health checks are green. Apps with long startup times
> (e.g. those with migrations or cache building at startup) need some time after
> the run before they are fully ready.

## Logging

One file `logs/backup-<timestamp>.log` per run. Output also goes to stdout at
the same time. Files older than `LOG_RETENTION_DAYS` (default 64) days are
deleted at the start of each run — no logrotate needed.

## Cron

The script must run as **root**. Edit the root user's crontab:

```bash
sudo crontab -e
```

Daily backup at 03:00:

```cron
# m h dom mon dow  command
0 3 * * * /path/to/location/restic-backup.sh
```

`restic`/`rclone` are often located under `/usr/local/bin`, which may be missing
from the cron environment. To be safe, set `PATH`:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Daily backup at 03:00
0 3 * * * /path/to/location/restic-backup.sh
```

The script writes its own log file to `logs/` per run and reports the result via
Telegram — an additional cron redirect is not needed. If you still want to
capture the cron output (e.g. the script's startup error):

```cron
0 3 * * * /path/to/location/restic-backup.sh >> /path/to/location/logs/cron.log 2>&1
```

### NAS systems

Many NAS systems ship with their own GUI task scheduler and advise against
editing the crontab directly. In that case, set up the task there as the user
`root` and give the absolute path to the script as the command:

```bash
/path/to/location/restic-backup.sh
```

Telegram delivers the result; the full log is in `logs/`.

## Not included in the script (manual)

- Repository initialisation (`restic init`)
- rclone configuration (`rclone config`) — only for `rclone:` targets
- restic updates (`restic self-update`)
- Cron setup

## Requirements

The following must be available on the host:

| Tool | Purpose | Note |
|---|---|---|
| `bash` | script interpreter | works even with old Bash 3.2 |
| `docker` incl. **Compose V2 plugin** | stop/start stacks | the script uses the plugin syntax **`docker compose`** (with a space), **not** the old `docker-compose` (with a hyphen) |
| `restic` | backup, forget/prune, check | |
| `rclone` | only for `rclone:` targets | **optional** — not needed for local/SFTP/S3/REST targets; set up remotes beforehand via `rclone config` |
| `curl` | Telegram notification | only needed if Telegram is configured |
| `jq` | parse restic's JSON output | **optional** — without `jq` a `grep` fallback is used |

Check whether the Compose V2 plugin is present:

```bash
docker compose version
```

If this returns an error (e.g. "is not a docker command"), only the outdated
`docker-compose` is installed — in which case the Compose plugin needs to be
added.
