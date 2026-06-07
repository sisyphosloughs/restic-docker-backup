# restic-docker-backup

Automated restic backups for Docker stacks on various hosts (e.g. a Linux VPS
or a NAS). A single script, with host-specific configuration in separate files
in the same directory. Any backend supported by restic can serve as the backup
target (local, SFTP, S3, REST, …); rclone is optional and only needed for
`rclone:` targets.

What gets backed up is described **per object** in `instances/<name>.conf` —
one file per directory you want to back up. Each instance can optionally enable
Docker stack orchestration (DB dumps + stopping/starting stacks for a consistent
backup); this is **off by default** per instance. The global switches (binaries,
repository list, Telegram, …) live in `global.conf`.

## Files

```
<location>/
├── restic-backup.sh             # the script (identical on all hosts)
├── global.conf                  # host-specific global config (from global.conf.example)
├── instances/                   # one *.conf per backed-up object
│   ├── instances.conf.example   # template for an instance
│   └── <name>.conf              # e.g. containers.conf, audiobooks.conf
├── repos.conf                   # host-specific repository list (from repos.conf.example)
├── repo.password                # restic password (chmod 600, owned by root)
├── lib/
│   └── db-dump-lib.sh           # shared DB-dump library, sourced by each stack's db-dump.sh
├── examples/                    # thin db-dump.sh templates to copy into a stack (postgres/mariadb/sqlite)
└── logs/                        # one log file per run (auto-rotated), created by the script
```

The script determines its own location at runtime; all paths are derived from
`SCRIPT_DIR`. The location is freely choosable.

## Configuration model

Configuration is split in two:

- **`global.conf`** — switches that apply to the whole run: `DRY_RUN`,
  `REPOS_FILE`, `RESTIC_BIN` / `RCLONE_BIN`, `RCLONE_CONFIG_FILE`,
  `RESTIC_PASSWORD_FILE`, the Telegram credentials, `DOCKER_STOP_TIMEOUT` and
  `LOG_RETENTION_DAYS`.
- **`instances/<name>.conf`** — one file per object (directory) to back up. The
  script collects every `*.conf` in `instances/`. The file name (without
  `.conf`) is the instance name shown in the log. Each file may set:

  | Variable | Default | Meaning |
  |---|---|---|
  | `BACKUP_PATH` | — (required) | Directory to back up. For a Docker object this is the **base** directory whose sub-directories are the stacks. |
  | `EXCLUDES` | empty | restic exclude patterns anchored to this instance's `BACKUP_PATH` (see below). |
  | `DOCKER` | `false` | `true` → run `db-dump.sh` + stop/start the stacks under `BACKUP_PATH` for a consistent backup. |
  | `STOP_STACKS` | empty | Which sub-stacks to stop/start (empty = all); only relevant when `DOCKER=true`. |

> **Why `BACKUP_PATH` and not `PATH`?** `PATH` is the shell's executable search
> path — a config file that set `PATH=…` would break command lookup for the rest
> of the run. The per-object variable is therefore `BACKUP_PATH`.

**How the instances are combined:** all `BACKUP_PATH`s across all instances are
backed up **together in one `restic backup` call per repository** — one snapshot
per repo. Each instance's `EXCLUDES` are **anchored to its own `BACKUP_PATH`**
by the script, so a pattern only affects the path it was defined for (see
[Backup paths and excludes](#backup-paths-and-excludes-backup_path--excludes)).
The Docker orchestration runs as soon as **at least one** instance has
`DOCKER=true`.

## Setup

1. **Clone the repository / place the files** anywhere you like.

2. **Create the global configuration** (host-specific):
   ```bash
   cp global.conf.example global.conf
   cp repos.conf.example repos.conf
   $EDITOR global.conf repos.conf
   ```

3. **Create one instance per object to back up:**
   ```bash
   cp instances/instances.conf.example instances/audiobooks.conf
   cp instances/instances.conf.example instances/containers.conf
   $EDITOR instances/audiobooks.conf instances/containers.conf
   ```
   Set `BACKUP_PATH` in each, plus `EXCLUDES` / `DOCKER` / `STOP_STACKS` as
   needed. At least one valid instance is required, or the run aborts.

4. **Store the restic password**:
   ```bash
   sudo sh -c 'echo "YOUR-RESTIC-PASSWORD" > repo.password'
   sudo chown root:root repo.password
   sudo chmod 600 repo.password
   ```

5. **Configure rclone** (only if `rclone:` targets are used):
   ```bash
   rclone config        # create remotes, e.g. pcloud, s3, b2
   ```
   This step is not needed for local, SFTP, S3 or REST targets.

   > **Important:** The backup script runs as **root**. If `rclone config` is
   > run as a normal user, the `rclone.conf` ends up in that user's home
   > (`~/.config/rclone/rclone.conf`) and is **not readable** by root — all
   > `rclone:` targets are then treated as "not reachable" and skipped.
   > Remedy: either run `rclone config` as root straight away
   > (`sudo rclone config`), **or** set `RCLONE_CONFIG_FILE` in `global.conf` to
   > the absolute path of the `rclone.conf`. The script checks this at startup
   > and writes a corresponding note to the log.

6. **Initialise the repositories** (manually, once per target):
   ```bash
   # local target
   restic --repo /mnt/backup/restic-<host> \
     --password-file ./repo.password init

   # or via rclone
   restic --repo rclone:pcloud:restic-<host> \
     --password-file ./repo.password init
   ```

   > **rclone on a NAS / non-standard setup:** if `rclone` is not in `PATH` and
   > the `rclone.conf` is not at root's default location, `restic init` must be
   > told the same way the script tells it (otherwise you get
   > `Config file ... not found` or `directory not found`). Mirror `RCLONE_BIN`
   > and `RCLONE_CONFIG_FILE` from `global.conf`:
   > ```bash
   > restic \
   >   -o rclone.program=/volume1/opt/bin/rclone \
   >   -o "rclone.args=serve restic --stdio --b2-hard-delete --config /volume1/homes/USER/rclone.conf" \
   >   --repo rclone:pcloud:/Backup/restic-<host> \
   >   --password-file ./repo.password init
   > ```

7. **Set up DB dumps** (optional, per stack; requires a Docker instance with
   `DOCKER=true`):
   Place an executable `db-dump.sh` in each stack directory. Templates are in
   [examples/](examples/) (PostgreSQL, MariaDB/MySQL, SQLite). They are **thin
   wrappers**: the generic logic — creating `db-dumps/`, deleting old dumps
   (retention), timestamped filenames and logging — lives once in
   [lib/db-dump-lib.sh](lib/db-dump-lib.sh), which each wrapper `source`s. A
   wrapper only supplies the DB-specific call (e.g. `dump_postgres database-1`).

   Two settings live in each wrapper:

   - `DB_DUMP_LIB` — path to the shared library. `restic-backup.sh` passes its
     own bundled `lib/db-dump-lib.sh` automatically; the default in the wrapper
     only matters for **standalone** runs (`./db-dump.sh`) — adjust it to where
     you placed restic-docker-backup.
   - `RETENTION_DAYS` — how many days dumps are kept (rotation), set **per
     stack**. There is deliberately no global value, so each `db-dump.sh` is
     self-contained and can be tested on its own.

   For the server databases (PostgreSQL, MariaDB) the dump is written to the bind
   mount `db-dumps/` (`/tmp/dumps` inside the container) so it is backed up as
   well. SQLite has no server: the dump runs on the host and writes straight into
   `db-dumps/`. `STACK_NAME` (container prefix) is set by the backup script;
   `STACK_DIR` is derived automatically.

## Docker stack management (`DOCKER`)

Stopping/starting Docker stacks (and running their `db-dump.sh` scripts) for a
consistent backup is **optional and off by default**, decided per instance:

```bash
# instances/containers.conf
BACKUP_PATH="/opt/containers"
DOCKER=false   # default — back up the path, never touch containers
# DOCKER=true  # run DB dumps + stop/start stacks for the backup
```

- **`DOCKER=false` (default)** → the instance's `BACKUP_PATH` is backed up while
  the containers keep running. This is a *crash-consistent* backup — fine for
  most file data, but databases with open files may not be captured in a clean
  state.
- **`DOCKER=true`** → `BACKUP_PATH` is treated as a **base directory** whose
  sub-directories are Docker stacks. Before the backup the script runs each
  selected stack's `db-dump.sh`, then `docker compose stop`, and afterwards
  `docker compose start`. Which stacks are affected is controlled by
  `STOP_STACKS` (below).

`docker` plus the Compose V2 plugin are required (and checked at startup) **as
soon as any instance has `DOCKER=true`** — never otherwise. Multiple Docker
instances are allowed; their stacks are all handled in the one stop/start cycle.

## Which stacks are stopped? (`STOP_STACKS`)

> Only relevant for an instance with `DOCKER=true`.

**The whole of a Docker instance's `BACKUP_PATH` is always backed up** —
including stacks that are already stopped or permanently inactive. The
`STOP_STACKS` array solely controls which sub-stacks are **stopped and then
started again** for a consistent backup (and for which `db-dump.sh` runs):

- **`STOP_STACKS` empty** → all stacks under `BACKUP_PATH` are stopped and
  started again.
- **`STOP_STACKS` populated** (sub-directory names under `BACKUP_PATH`) → only
  these stacks are stopped/started. All others are left untouched — they are
  neither stopped nor (re)started, but are still backed up.

```bash
# instances/containers.conf — stop/start only these running stacks for the backup
DOCKER=true
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

## Backup paths and excludes (`BACKUP_PATH` / `EXCLUDES`)

Each instance contributes its `BACKUP_PATH`; all of them are backed up together
(one snapshot per repo). `EXCLUDES` holds exclude patterns that apply **only
under this instance's `BACKUP_PATH`** — patterns from different instances do not
interfere with each other.

```bash
# instances/documents.conf
BACKUP_PATH="/srv/documents"
EXCLUDES=(
  "@eaDir"          # only excludes "@eaDir" under /srv/documents
  "*.tmp"           # only excludes *.tmp under /srv/documents
  "/srv/data/cache" # leading "/" → verbatim; anchored to /srv/data/cache
)
```

**How anchoring works:** restic's `--exclude` is global per backup call, so the
script automatically prepends each relative pattern with the instance's
`BACKUP_PATH` before passing it to restic. A relative pattern `<pat>` from an
instance with `BACKUP_PATH=/srv/documents` becomes two anchored forms:

- `/srv/documents/<pat>` — matches directly in the base directory
- `/srv/documents/**/<pat>` — matches at any depth below it

A pattern that **already starts with `/`** is used verbatim — the escape hatch
for patterns that span multiple paths or that you want to anchor yourself.

The resolved backup paths and active (anchored) excludes are written to the log
at the start of the backup step.

## Program paths (`RESTIC_BIN` / `RCLONE_BIN`)

By default the script calls `restic` and `rclone` as found in `PATH`. On some
hosts — e.g. a NAS — the binaries live in a non-standard location that is not in
the (cron) `PATH`, for instance `/volume1/opt/bin`. In that case set the
absolute paths in `global.conf`:

```bash
# global.conf
RESTIC_BIN="/volume1/opt/bin/restic"
RCLONE_BIN="/volume1/opt/bin/rclone"
```

restic launches rclone as a subprocess. The script passes the configured path
on via restic's `-o rclone.program=$RCLONE_BIN` option, so **rclone does not
need to be in `PATH`** — a fixed path is sufficient for both the reachability
check and the actual backup.

Leave the variables empty (the default) to use whatever is found in `PATH`.

At startup the script checks and logs the availability of all required programs:
`restic` (always), and — depending on the configuration — `docker` incl. the
Compose V2 plugin (only if any instance has `DOCKER=true`), `rclone` (only if
`rclone:` targets exist), `curl` (only if Telegram is configured) and `jq`. A
missing `restic` aborts the run; the other tools are logged as errors/notes.
This makes a mislocated binary obvious in the log instead of surfacing as a
cryptic failure later.

## Running

The script must run with root privileges so that all files in the Docker stack
directories are readable:

```bash
sudo ./restic-backup.sh
```

Exit code: `0` on success, `1` on one or more errors.

## Dry run (`DRY_RUN`)

Set `DRY_RUN=true` in `global.conf` to do a trial run without writing anything.
restic then runs the backup with `--dry-run --verbose=2`, so a per-file listing
of what *would* be backed up (including which files your excludes skip) is
written to the log. No snapshot is created, and the repository-modifying
steps — `forget`/`prune` and the monthly `check` — are skipped. Handy for
verifying `BACKUP_PATH` / `EXCLUDES` before a real run:

```bash
# global.conf
DRY_RUN=true
```

The log and the Telegram message are marked with `[DRY RUN]`. Set it back to
`false` (the default) for normal operation.

## Workflow

1. Initialisation, open log file, load `global.conf`, collect `instances/*.conf`,
   check program availability, delete old logs, unlock repos
2. Run DB dumps per stack — *only if at least one instance has `DOCKER=true`*
3. Stop stacks (`docker compose stop`) — *only if `DOCKER=true` instances exist*
4. Back up all instance `BACKUP_PATH`s (with merged excludes) to each reachable
   target — one snapshot per repo
5. Start stacks again (`docker compose start`) — *only if `DOCKER=true` instances exist*
6. `restic forget --prune` (keep-daily 31, keep-monthly 99)
7. `restic check` — monthly only (on the 1st)
8. Summary to the log + Telegram notification

When no instance has `DOCKER=true` (default), steps 2/3/5 are skipped entirely
and the data is backed up while the containers keep running.

With `DRY_RUN=true`, step 4 runs as `restic backup --dry-run --verbose=2`
(nothing written, per-file output to the log) and steps 6/7 are skipped.

If the script is aborted unexpectedly (`INT`/`TERM`/error) while stacks were
stopped, a trap handler brings them back up and sends a Telegram warning.

> **Note:** `docker compose start` returns as soon as the containers are
> running, not as soon as health checks are green. Apps with long startup times
> (e.g. those with migrations or cache building at startup) need some time after
> the run before they are fully ready.

## Logging

One file `logs/backup-<timestamp>.log` per run. Output also goes to stdout at
the same time. Files older than `LOG_RETENTION_DAYS` (default 64) days are
deleted at the start of each run — no logrotate needed. Log files are created
world-readable (`0644`) so the normal user can read/sync them even though the
script runs as root; they contain paths and snapshot IDs but no secrets.

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

Alternatively (or for binaries in non-standard locations such as a NAS's
`/volume1/opt/bin`), set `RESTIC_BIN` / `RCLONE_BIN` to absolute paths in
`global.conf` — see [Program paths](#program-paths-restic_bin--rclone_bin). The
startup program check then confirms in the log that the binaries were found.

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
| `docker` incl. **Compose V2 plugin** | stop/start stacks | **only required when an instance has `DOCKER=true`** (and only then checked at startup). The script uses the plugin syntax **`docker compose`** (with a space), **not** the old `docker-compose` (with a hyphen) |
| `restic` | backup, forget/prune, check | found in `PATH`, or set `RESTIC_BIN` to an absolute path |
| `rclone` | only for `rclone:` targets | **optional** — not needed for local/SFTP/S3/REST targets; set up remotes beforehand via `rclone config`. Found in `PATH`, or set `RCLONE_BIN` to an absolute path (no `PATH` entry needed then) |
| `curl` | Telegram notification | only needed if Telegram is configured |
| `jq` | parse restic's JSON output | **optional** — without `jq` a `grep` fallback is used |

Check whether the Compose V2 plugin is present:

```bash
docker compose version
```

If this returns an error (e.g. "is not a docker command"), only the outdated
`docker-compose` is installed — in which case the Compose plugin needs to be
added.
