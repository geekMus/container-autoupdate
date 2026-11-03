# Options and environment variables

> Language: [English](parameters.en.md) | [中文](parameters.md)

## Options

| Option | Default | Meaning |
|---|---|---|
| `--compose <name>` | — | Compose project name (the one in DPanel). Mutually exclusive with `--container` |
| `--container <name>` | — | A single container name. Mutually exclusive with `--compose` |
| `--compose-dir <path>` | discovered | Compose project directory; only needed when discovery fails |
| `--docker-sock <path>` | empty | Docker socket passed to the docker CLI |
| `--dpanel-container <name>` | `dpanel` | DPanel container name |
| `--dpanel-bin <path>` | `/app/server/dpanel` | DPanel CLI path inside the container |
| `--dpanel-docker-env <name>` | `local` | Docker environment name inside DPanel |
| `--dry-run` | off | Check only, change nothing |
| `-h` / `--help` | — | Show help |
| `-V` / `--version` | — | Show version |

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | empty | Same as `--compose` / `--container` |
| `COMPOSE_DIR` | empty | Same as `--compose-dir` |
| `DOCKER_SOCK` | empty | Same as `--docker-sock` |
| `DOCKER_HOST` | empty | Passed straight to the docker CLI |
| `DPANEL_NAME` / `DPANEL_BIN` / `DPANEL_DOCKER_ENV` | `dpanel` / `/app/server/dpanel` / `local` | See the matching options |
| `DRY_RUN` | `0` | Same as `--dry-run` |
| `T_HARD` | `540` | Hard limit for one round (seconds) |
| `DP_T_CHECK` | `120` | Container mode: wait limit for the check (the old name `T_INSPECT` still works) |
| `DP_T_UPGRADE` | `420` | Container mode: wait limit for the upgrade |
| `DP_T_PULL` | `420` | Compose mode: wait limit for `docker compose pull` |
| `DP_T_UP` | `180` | Compose mode: wait limit for `docker compose up -d` |
| `DP_MIN_UPGRADE` | `90` | Do nothing when the remaining budget is below this |

Command-line options win over same-named environment variables. Every wait limit is narrowed further by the remaining budget.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or nothing to update |
| 1 | Configuration/environment error, or the update did not complete (target untouched) |
| 130 | Interrupted by Ctrl-C (SIGINT) |
| 143 | Interrupted by SIGTERM / SIGHUP (common when a scheduled task times out) |
