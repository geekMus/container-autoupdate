# All parameters and environment variables

> Language: [English](parameters.en.md) | [中文](parameters.md)

> The script is meant for a **DPanel scheduled task**: it runs one round and exits; frequency and concurrency are left to DPanel.
> One scheduled task per target is enough (the script no longer takes a mutex lock internally).
> Running it manually is allowed too — that is just a one-off run; wrapping it in cron / a systemd timer is not recommended.

## Specifying a target

Exactly one of the two target kinds **must be specified**.

| Parameter | Description |
|---|---|
| `--compose <project>` | Compose project name, i.e. the project name used by `docker compose` (usually the directory name; `docker compose ls` shows it) |
| `--container <container>` | Container name, i.e. the `NAMES` column of `docker ps` |

Three ways to specify it, in priority order: **command line > environment variable > the config block at the top of the script**.

```sh
# 1. Command line
container-autoupdate.sh --compose myapp

# 2. Environment variable
UPD_COMPOSE=myapp container-autoupdate.sh

# 3. Edit the config block at the top of the script (good for a fixed purpose)
COMPOSE_NAME="myapp"
CONTAINER_NAME=""
```

## Dependencies

The script runs a dependency self-check before it does anything; if any of them is missing it prints `ERR 缺少依赖命令：xxx` ("ERR: missing dependency command: xxx") and ends with exit code `1`,
instead of blowing up halfway through.

| Command | Purpose | Typical case where it is missing |
|---|---|---|
| `docker` | The prerequisite for every operation | — |
| `docker buildx` | **The only way to query the remote digest** (`docker buildx imagetools inspect`) | Minimal Docker installs, systems with only the `docker.io` package. Without it the script errors out before it does anything — otherwise every round would falsely report `无法获取远端 digest` ("cannot fetch the remote digest") and send you chasing network problems |
| `curl` | Pulling images goes through the Docker Engine API stream (used to detect a stalled pull), and querying the remote digest | Minimal images |
| `timeout` | Every external call has a timeout, so the whole round cannot be SIGKILLed by the execution timeout of the scheduled task | Present in busybox; missing in some minimal images |
| `sed` `awk` `grep` | Parsing `docker inspect` output | The busybox set is enough; the GNU version is not needed |

On the Docker side you also need the **Compose v2 plugin** (`docker compose`, not the old `docker-compose`),
which is only needed in compose mode; container mode does not need it.

## Bootstrapper (`ct-bootstrap.sh`) parameters and environment variables

The bootstrapper is the recommended way to run it: it takes care of downloading and caching the main script, so you only maintain one command line.
It needs `curl` itself (for probing and downloading) and `sh`; the remaining dependencies are the same as the main script's.

Two ways to specify them, in priority order: **command line `--ct-*` > environment variable `CT_*`**
([parameter reference](parameters.en.md#bootstrapper-ct-bootstrapsh-parameters-and-environment-variables)). Bootstrapper options must come before the main script's arguments; you can also use `--` to separate them explicitly.

| Command line | Environment variable | Default | Description |
|---|---|---|---|
| `--ct-version <version>` | `CT_VERSION` | empty | **Setting it means fixed-version mode** (e.g. `1.2.3`, with or without the `v` prefix): it does not probe the remote side, runs the local copy if there is one, and **never touches the network**. Recommended in production; the version numbers are on the Releases page. |
| `--ct-cache-dir <dir>` | `CT_CACHE_DIR` | `/var/cache/container-autoupdate` | The script cache directory. When running inside a container, mount a writable directory or change it to `/tmp`. |
| `--ct-cache-keep <N>` | `CT_CACHE_KEEP` | `3` | How many historical version files to keep; the extra ones are deleted. `0` means no pruning. |
| `--ct-source <source>` | `CT_SOURCE` | `auto` | Download source: `auto` (**self-hosted mirror → gh-proxy → direct → ghproxy.net**), `direct`, `gh-proxy`, `ghproxy`, `mus` (self-hosted mirror), or any custom prefix (it is prepended to `https://github.com/...`). |
| `--ct-t-net <seconds>` | `CT_T_NET` | `20` | Timeout for a single network operation (seconds). Applies to probing and to downloading separately. |
| `--ct-tries <N>` | `CT_TRIES` | `2` | How many attempts per source. |
| `--ct-probe-bytes <N>` | `CT_PROBE_BYTES` | `16000` | How many bytes of the head of the file to fetch when probing for the version number (a `Range` request). **Do not lower it**: the version line moves further down as the script grows, and a window that no longer covers it fails to find the version (it shows up as "probe failed"). When the version is not found, the bootstrapper fetches the whole file once and parses it again. |
| `--ct-force` | `CT_FORCE=1` | off | Ignore the cache and force a re-download. |
| `--ct-quiet` | `CT_QUIET=1` | off | Do not print the bootstrapper's own logs (the main script's logs are unchanged). |
| `--ct-help` | — | — | Show the bootstrapper's help. |

```sh
# Command line (recommended for the script box of a DPanel scheduled task)
ct-bootstrap.sh --ct-version 1.2.3 --compose myapp

# Environment variable (compatible with the old style)
CT_VERSION=1.2.3 ct-bootstrap.sh --compose myapp

# Mixed: the command line overrides the environment variable; everything after -- goes to the main script
CT_SOURCE=auto ct-bootstrap.sh --ct-source direct --ct-version 1.2.3 -- --compose myapp --dry-run
```

Bootstrapper behaviour at a glance:

| Situation | Result |
|---|---|
| Fixed version set (`--ct-version` / `CT_VERSION`) and the local copy exists | Runs it directly, **zero network requests** |
| Fixed version set and no local copy | Downloads that version and runs it (only the fixed tag is tried; `latest` is never used) |
| No fixed version, a version was probed and it is already local | Sends a single Range request (fetches the head of the file, 16KB by default), no download |
| No fixed version, a newer version was probed | Downloads the whole file and caches it, then runs it |
| Probe failed and a usable cache exists | Runs from the cache and logs `WARN` (the exit code depends on the main script) |
| Probe failed and no cache | `ERR`, exit code `1` (**never a silent success**) |
| The cache file is corrupted | Re-downloads it automatically (validation: syntax + `VERSION` field + signature string) |

> Why the default sources are not a direct connection: in testing (2026-11-03, inside the N1 dpanel container) both the self-hosted mirror `github.mus.pp.ua` and the public mirror `gh-proxy.com` correctly forward Release assets (the sha256 matches the official one), but the self-hosted one occasionally times out after 40 seconds (3 of 5 attempts succeeded) while `gh-proxy.com` succeeded 5 out of 5 times in about 1 second. The default order is **self-hosted first (fast, and under your own control), public as the fallback**, then direct, then `ghproxy.net`.
>
> To use one specific source only, set `--ct-source mus` / `--ct-source gh-proxy` / `--ct-source direct` / `--ct-source ghproxy`, or the same values through `CT_SOURCE=`.


## All command-line parameters

| Parameter | Default | When you need it |
|---|---|---|
| `--compose <name>` | none | Required in compose mode |
| `--container <name>` | none | Required in container mode |
| `--compose-dir <dir>` | auto-discovery | **When the Compose project directory cannot be discovered from container labels.** Normally the script reads the directory from the labels of the running container, so you do not need to fill this in. When no container of the project is running, or the container was created in an unusual way, the script errors out with `请用 --compose-dir 指定项目目录` ("use `--compose-dir` to specify the project directory"); add this option then |
| `--docker-sock <path>` | `DOCKER_HOST` or `/var/run/docker.sock` | When the Docker socket is **not in the default location**. Rootless Docker (`/run/user/1000/docker.sock`), Docker on another machine, the socket mounted at an unusual path |
| `--state-dir <dir>` | `/tmp/.container-autoupdate` | When `/tmp` is wiped on reboot but you want an interrupted run to be recoverable across reboots; or `/tmp` is tight on space; or you want the tasks of different users not to interfere with each other |
| `--bad-ttl-days <days>` | `7` | The bad-version pinning period. If a new version keeps failing to come up and you want to retry sooner, lower it (e.g. `1`); raise it to be more conservative |
| `--pull-retries <times>` | `1` | How many times to retry after a failed pull. `0` = no retry (the old behaviour); raise it to `2`~`3` when the network is unstable or the upstream often returns transient 5xx. **A stalled pull (60 seconds without bytes) is not retried**, the round is abandoned right away |
| `--compat <version>` | off | **Declares "I have only verified up to a certain version"**. If the script is newer than that and there are breaking changes in between, it stops hard instead of running at your own risk (exit code `3`). Use it when the behaviour changed after you upgraded the script and you want to hold the current state first |
| `--dry-run` | off | Check only, change nothing: no container changes, no image tag changes, no cleanup of old images (it only writes to the state directory). **First-time integration**, debugging "why did it not update", confirming how a given container would be handled |
| `-h` / `--help` | — | Show the help |
| `-V` / `--version` | — | Show the version number |

## All environment variables

| Variable | Corresponding parameter | When you need it |
|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | `--compose` / `--container` | The Environment panel of DPanel, or one command serving several targets |
| `COMPOSE_DIR` | `--compose-dir` | Same as above |
| `COMPOSE_BASE` | — | The **fallback root path** of the Compose directory; the script tries `$COMPOSE_BASE/<project>`. Only useful in a self-built environment; DPanel users do not need it |
| `DOCKER_SOCK` | `--docker-sock` | Same as above |
| `DOCKER_HOST` | — | If this standard variable is set the script uses it directly; `unix:///path` and `tcp://host:port` are supported |
| `DRY_RUN=1` | `--dry-run` | Same as above |
| `BAD_TTL_DAYS` | `--bad-ttl-days` | Same as above |
| `PULL_RETRIES` | `--pull-retries` | Same as above |
| `DIGEST_RETRIES` | — | How many times to retry when querying the remote digest fails (default `2`; `0` = no retry) |
| `DIGEST_RETRY_WAIT` | — | Seconds between the remote digest retries (default `5`) |
| `COMPAT_UNTIL` | `--compat` | Same as above |
| `STATE_ROOT` | `--state-dir` | Same as above |

## Timeout parameters

**You rarely need to change these.** Before changing them, make sure: the script's own hard limit (`T_HARD`) must be smaller than the "execution timeout" of the DPanel scheduled task.

| Variable | Default | Meaning | When to tune it |
|---|---|---|---|
| `T_HARD` | 540 seconds | Hard limit for the whole script | Lower it when the scheduled task's timeout is shorter |
| `T_INSPECT` | 30 seconds | Timeout for querying the remote digest | The registry responds slowly |
| `T_STALL` | 60 seconds | **Stalled pull** detection: if no new bytes arrive within this window the pull is judged stalled and killed | Raise it when the network is very slow and even a healthy pull stays silent for a long time (e.g. `120`) |
| `T_PULL_MAX` | 300 seconds | Absolute limit for a single pull | The image is very large |
| `T_UP` | 60 seconds | Timeout for recreating / starting the container | The container starts slowly |
| `T_HEALTH` | 120 seconds | **Wall-clock wait limit of the health gate** (the one that actually applies) | Raise it when the application starts slowly (common for Java services), and raise `T_HARD` and the scheduled task's "execution timeout" at the same time |
| `HEALTH_TRIES` | `0` (unset) | Hard cap on the **additional** number of health check polls; `0` means the poll count is bound only by the `T_HEALTH` seconds | Use it when you only want to cap the number of polls and not touch the seconds |
| `T_ROLLBACK` | 60 seconds | Timeout for the rollback operation | The rollback is slow |
| `PLAIN_BOOT` | 30 seconds | For a container **without a healthcheck**, how long to watch it after start before calling it stable | Raise it for containers that start slowly |

## Common scenarios and how to configure them

| Scenario | Configuration |
|---|---|
| An ordinary Compose project | `--compose myapp`, everything else default |
| An ordinary `docker run` container | `--container mycontainer`, everything else default |
| All project containers are stopped and the script says it cannot find the directory | Add `--compose-dir /path/to/project` |
| Rootless Docker | Add `--docker-sock /run/user/1000/docker.sock` |
| You want to see the effect first | Add `--dry-run` |
| The application starts very slowly (healthy only after >120 seconds) | `T_HEALTH=300` (and `T_HARD=600` if needed), and raise the "execution timeout" of the DPanel scheduled task to 700+ at the same time |
| The registry often hangs and does not return | `T_STALL=120` (do not make it too small; even a healthy pull can stay silent for a long time) |
| The same new version keeps failing and you want to retry sooner | `--bad-ttl-days 1` |
| Pulls often fail because of network jitter | `--pull-retries 2` (the default is 1; `0` = no retry) |
| The remote digest often cannot be fetched (slow or jittery registry) | It is already retried twice by default; raise it to `DIGEST_RETRIES=4` and `DIGEST_RETRY_WAIT=10` if that is not enough |
| The scheduled task only shows "exit status 1" and no reason | See [Where the failure reason is written](#where-the-failure-reason-is-written) |
| The script has been upgraded but you want to keep the current behaviour first | `--compat <the version you have verified>`, e.g. `--compat 1.2.3` |

## Where the failure reason is written

The script's output goes to two streams:

- **stdout**: the complete log (including every `ERR` / `CRITICAL` line and its indented follow-up lines).
- **stderr**: **the failure reason only** — the `ERR` / `CRITICAL` lines and the indented follow-up lines right after them.

Why a separate stderr copy: a scheduled task (DPanel) keeps **only stderr** when the task **fails** and discards stdout.
Earlier versions wrote the failure reason to stdout only, so the scheduled task was left with nothing but a bare `exit status 1` and nothing to debug with.
Now the failure reason is written to both streams: the log stays complete, and the scheduled task shows the reason directly.

```
# This is what a failed scheduled task shows (stderr)
[2026-11-03 06:00:12] ERR 无法获取 ghcr.1ms.run/yetone/magpie:latest 远端 digest（已尝试 2 次），本轮跳过整个项目
```

When you run it by hand both streams land on the terminal, so there is no visible difference; you can also look at them separately:

```sh
sh container-autoupdate.sh --compose myapp >/tmp/ct.out 2>/tmp/ct.err
# /tmp/ct.out holds the complete log, /tmp/ct.err only the failure reason
```

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | Success / already up to date / skipped by rule | Nothing to do |
| `1` | A configuration or environment error, or the update could not be completed this round (**the container is left as it was**) | Look for `ERR` in the log, fix the configuration and run it again |
| `2` | The rollback itself failed, **manual intervention is required** (the failure scene is preserved in `--state-dir`) | Recover manually as the log says, then delete the state directory |
| `3` | **A breaking change was detected**, your invocation is no longer valid (nothing was changed this time) | Follow the `迁移方式` ("migration path") in the log to fix the command; or pin the version; or add `--compat` |
| `130` | Interrupted by `SIGINT` (Ctrl-C) | You pressed Ctrl-C during a manual run; no problem |
| `143` | Interrupted by `SIGTERM` / `SIGHUP` (most common when the scheduled task times out) | The "execution timeout" is too short; raise it or lower `T_HARD` |
