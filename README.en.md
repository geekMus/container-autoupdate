# container-autoupdate

> Language: [English](README.en.md) | [中文](README.md)

A single-file, no-dependency (`sh` + `docker`) container auto-update script **for DPanel scheduled tasks**.

It never does the dangerous part itself: containers are upgraded by DPanel, Compose projects are redeployed by `docker compose`.

## What it is

One run = one check. **Frequency, start/stop and timeouts belong to DPanel's scheduled task**; the script has no timer logic.

- **Container mode**: ask DPanel "is there a newer version?", then let DPanel upgrade it (DPanel keeps a `<container>-bak-<timestamp>` backup container — that is the rollback point).
- **Compose mode**: run `docker compose pull` once, and only `up -d` if something changed. The project directory is discovered from container labels; use `--compose-dir` if that fails.

## Install (DPanel scheduled task)

Create a scheduled task in DPanel and paste the whole block below into its script box (hourly, timeout 600s):

```sh
SRC='https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
https://ghfast.top/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh'
T=/tmp/ct-new.sh
okfile() { [ "$(wc -c <"$1" 2>/dev/null || echo 0)" -gt 1000 ] && sh -n "$1" 2>/dev/null && grep -q container-autoupdate "$1"; }
for u in $SRC; do
  curl -fsSL --max-time 30 "$u" -o "$T" 2>/dev/null || continue
  okfile "$T" && break
done
okfile "$T" && mv -f "$T" /tmp/container-autoupdate.sh
[ -s /tmp/container-autoupdate.sh ] || { echo "ERR 拿不到可用的更新脚本"; exit 1; }
sh /tmp/container-autoupdate.sh --compose myapp
```

- `SRC` holds one mirror per line, tried in order. **The content must pass the checks** — a mirror that returns an HTML page (like `gh-proxy.net`) is rejected even though its exit code is 0.
- If every mirror fails, the previous `/tmp/container-autoupdate.sh` is reused and still runs. Only when there is no copy at all do you get `ERR 拿不到可用的更新脚本` and rc=1.
- No `curl … | sh`: a pipe swallows download failures.
- To pin a version: replace `latest/download` with `download/v4.0.0` on every line of `SRC`.

## Two modes

| Target | Update action | Rollback point |
|---|---|---|
| Container (`--container`) | `dpanel container:upgrade` (check first, upgrade only if newer) | the `<container>-bak-<timestamp>` backup container DPanel creates |
| Compose (`--compose`) | `docker compose pull` + `docker compose up -d` | the old image is still local: `docker tag <old-image-id> <repo>:latest && docker compose up -d --force-recreate` |

## Common options

| Option | Meaning |
|---|---|
| `--compose <name>` | Compose project name (the one in DPanel) |
| `--container <name>` | A single container name |
| `--compose-dir <path>` | Project directory; discovered from container labels when omitted |
| `--dry-run` | Check only: container mode asks DPanel, Compose mode only lists images |
| `--dpanel-container <name>` | DPanel container name, default `dpanel` |
| `--dpanel-bin <path>` | DPanel CLI path, default `/app/server/dpanel` |
| `--docker-sock <path>` | Docker socket to use |
| `-h` / `-V` | Help / version |

`--compose` and `--container` are mutually exclusive.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | empty | Same as `--compose` / `--container` |
| `COMPOSE_DIR` | empty | Same as `--compose-dir` |
| `DOCKER_SOCK` / `DOCKER_HOST` | empty | Passed to the docker CLI |
| `DPANEL_NAME` / `DPANEL_BIN` / `DPANEL_DOCKER_ENV` | `dpanel` / `/app/server/dpanel` / `local` | DPanel settings |
| `T_HARD` | 540 | Hard limit for one round (seconds) |
| `DP_T_CHECK` / `DP_T_UPGRADE` | 120 / 420 | Container mode: wait limits for check / upgrade |
| `DP_T_PULL` / `DP_T_UP` | 420 / 180 | Compose mode: wait limits for `pull` / `up -d` |
| `DP_MIN_UPGRADE` | 90 | Do nothing when the remaining budget is below this |
| `DRY_RUN` | 0 | Same as `--dry-run` |

## Dry run and rollback

Run one round with `--dry-run` first to confirm the project name, directory and images the script sees:

```sh
docker exec -it dpanel sh -c 'sh /tmp/container-autoupdate.sh --compose myapp --dry-run'
```

Container rollback: restore the `<container>-bak-<timestamp>` backup container in the DPanel UI, or `docker stop/rm <name>`, `docker rename <name>-bak-<ts> <name>`, `docker start <name>`.

Compose rollback: the old image is still local — `docker tag` it back to `:latest` and run `up -d`. The script keeps no `:prev` tag and never rolls data back.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or nothing to update |
| 1 | Configuration/environment error, or the update did not complete (target untouched) |
| 130 | Interrupted by Ctrl-C |
| 143 | Interrupted by SIGTERM / SIGHUP (common when a scheduled task times out) |

## More documentation

- [How it works and what it cannot protect](docs/how-it-works.en.md)
- [All options and environment variables](docs/parameters.en.md)
- [Scheduled-task recipes, troubleshooting, FAQ](docs/advanced-usage.en.md)
- [Release process (maintainers)](docs/releasing.en.md)
- Inspect leftover processes and stale lock files: `curl -fsSL -L https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh -o /tmp/ct-stale-lock-check.sh && sh /tmp/ct-stale-lock-check.sh`
