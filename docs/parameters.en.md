# All parameters and environment variables

> Language: [English](parameters.en.md) | [中文](parameters.md)

> Since v2.0.0 the script **no longer pulls images and no longer recreates containers itself**: it only decides whether an update is due, hands the update over to DPanel, and reports the outcome faithfully.
> That is why it is meant for a **DPanel scheduled task**: it runs one round and exits; frequency and concurrency are left to DPanel, and one scheduled task per target is enough (the script takes no mutex lock internally).
> Running it manually is allowed too — that is just a one-off run; wrapping it in cron / a systemd timer is not recommended.

## Prerequisites: DPanel performs the update

The update capability comes from DPanel's own command line (`container:upgrade` / `compose:deploy`, shipped with DPanel 1.11.x); the script writes nothing to Docker itself (no pull, no tag, no create, no rm). Therefore:

- You must run it on a machine **with DPanel installed**.
- **Running it inside the dpanel container is recommended** (a DPanel scheduled task runs there by default): the script executes `/app/server/dpanel` directly and does not even need the local `docker` command.
- It can also run on the host or in another container: the script then uses `docker exec dpanel /app/server/dpanel ...`, which needs the `docker` command locally; when the container is not named `dpanel`, specify it with `--dpanel-container`.
- **Compose mode requires the project to be registered in DPanel** (DPanel web UI → Compose → create / import). When it is not, DPanel returns `commonDataNotFoundOrDeleted`; the script recognises it and prints two migration hints, exit code `1`.

The two modes:

| How your container was started | Which parameter to use | What the script actually runs |
|---|---|---|
| `docker compose up -d` | `--compose <project>` | `dpanel compose:deploy --name <project> --pull-image dpanel --docker-env <env>` |
| `docker run ...` | `--container <container>` | `dpanel container:upgrade --name <container> --docker-env <env>` (checks first without `--upgrade`, and adds `--upgrade` only when there really is a new version) |

The rollback point changed as well:

- In container mode the rollback point is the **backup container** DPanel creates, named `<container>-bak-<timestamp>` (for example `myapp-bak-20261103163808`); it runs the pre-upgrade image and is in the Exited state.
- Compose mode has **no backup container**; rollback can only rely on the old image still being local: `docker tag <old image ID> <repo>:latest && docker compose up -d --force-recreate`.
- The v1.x `<repo>:prev` tag and the `/tmp/.container-autoupdate/compose-*` transaction directory are no longer produced in v2.0.0.

## Specifying a target

Exactly one of the two target kinds **must be specified**. Giving both (`--compose a --container b`) fails immediately with exit code `1`, instead of silently letting the last one win.

| Parameter | Description |
|---|---|
| `--compose <project>` | Compose project name, i.e. the project name used by `docker compose` (usually the directory name; `docker compose ls` shows it). The project must already be registered in DPanel |
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

## All command-line parameters

| Parameter | Default | When you need it |
|---|---|---|
| `--compose <project>` | none | Required in compose mode. The project must already be registered in DPanel (see the previous section) |
| `--container <container>` | none | Required in container mode |
| `--docker-sock <path>` | empty (`DOCKER_HOST`, or the docker CLI default `/var/run/docker.sock`) | When the Docker socket is **not in the default location** (rootless Docker uses `/run/user/1000/docker.sock`; the socket may be mounted at an unusual path). Setting it makes the script `export DOCKER_HOST=unix://<path>`. It **only has an effect when the script is not inside the dpanel container**: that is the only case where it calls the local docker CLI |
| `--dpanel-container <name>` | `dpanel` | When the script is **not inside the dpanel container** and the DPanel container has another name (the script then calls the DPanel CLI through `docker exec <name> ...`) |
| `--dpanel-bin <path>` | `/app/server/dpanel` | When the DPanel CLI path inside the container is not the default. The script uses "this path is executable" to decide whether it is already inside the DPanel container, so a wrong path makes it think it must `docker exec` from outside |
| `--dpanel-docker-env <name>` | `local` | When the Docker server in your DPanel is not called `local` (it is the environment name under "Docker servers" in DPanel) |
| `--compat <version>` | off | **Declares "I have only verified up to a certain version"**. If the script is newer than that and there are breaking changes in between, it stops hard instead of running on; an invalid value (such as `1..2`) or a value newer than the script also stops it (exit code `3`). Use it when the script was upgraded and you want to hold the current state first |
| `--dry-run` | off | Check only, change nothing; **the two modes differ** (see below). Use it for first-time integration and when debugging "why did it not update" |
| `-h` / `--help` | — | Show the help |
| `-V` / `--version` | — | Show the version number |

### What `--dry-run` does in each mode

| Mode | What the script actually does | Exit code |
|---|---|---|
| Container | Calls DPanel's check interface (`container:upgrade` without `--upgrade`). If there is a new version it reports it and **does not upgrade**; the container is untouched | `0` |
| Compose | **Nothing at all**: DPanel offers no "check only" interface for Compose (`compose:deploy` is a deployment). The script prints an explanation and returns without deploying anything | `0` |

Container mode:

```text
[2026-11-03 06:00:12] 发现新版本（远端 digest=sha256:a5c10db1...）
[2026-11-03 06:00:12] DRY 只检查不动手，本轮不升级
    → Found a new version (remote digest=sha256:a5c10db1...)
    → DRY: check only, nothing is changed; no upgrade in this round
```

Compose mode:

```text
[2026-11-03 06:00:12] DRY Compose 模式没有「只检查」能力（DPanel 的 compose:deploy 会直接部署）
[2026-11-03 06:00:12]     本轮未执行部署；要检查容器有没有新版本请用 --container 模式
    → DRY: compose mode has no "check only" capability (DPanel's compose:deploy deploys directly)
    → Nothing was deployed this round; use --container mode to check whether a container has a new version
```

> To rehearse on Compose you can only use a test project; to "just look at the result", use container mode on the containers of that project.

## All environment variables

Command line > environment variable > the config block; the first three below are exactly equivalent to the parameter of the same name.

| Variable | Corresponding parameter | Default | When you need it |
|---|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | `--compose` / `--container` | empty | The Environment panel of DPanel, or one command serving several targets |
| `DOCKER_SOCK` | `--docker-sock` | empty | Same as above; setting it makes the script `export DOCKER_HOST=unix://$DOCKER_SOCK` |
| `DOCKER_HOST` | — | the docker CLI's own default | A standard docker CLI variable; the script does not override it. Both `unix:///path` and `tcp://host:port` work |
| `DPANEL_NAME` | `--dpanel-container` | `dpanel` | Same as above |
| `DPANEL_BIN` | `--dpanel-bin` | `/app/server/dpanel` | Same as above |
| `DPANEL_DOCKER_ENV` | `--dpanel-docker-env` | `local` | Same as above |
| `COMPAT_ROOT` | — | `/tmp/.container-autoupdate/compat` | The directory where the cross-version notice is recorded (one subdirectory per target, holding `lastver`). Change it to a persistent directory when `/tmp` is wiped on reboot or you want the record to survive |
| `COMPAT_UNTIL` | `--compat` | empty | Same as above |
| `DRY_RUN` | `--dry-run` | `0` | Setting it to `1` is equivalent to `--dry-run` |
| `T_HARD` | — | `540` | Hard limit for the whole round (seconds). Lower it when the scheduled task's "execution timeout" is shorter |
| `DP_T_CHECK` | — | `120` | Timeout in seconds for a single "check" call (`container:upgrade` without `--upgrade`, and the `version` self-check). Raise it when DPanel responds slowly |
| `T_INSPECT` | — | empty | **The old name, still accepted in v2.0.0**: it is used as the default of `DP_T_CHECK` only when `DP_T_CHECK` is unset, so the two are equivalent; when both are set, `DP_T_CHECK` wins |
| `DP_T_UPGRADE` | — | `420` | Timeout in seconds for a single "upgrade / deploy" call; it is additionally squeezed by the remaining budget (computed from `T_HARD`) |
| `DP_MIN_UPGRADE` | — | `90` | When the remaining budget is below this value the script does not start an upgrade, so the scheduled task cannot kill it halfway; both the container upgrade and the Compose deploy are bound by it |

## Time budget and the scheduled task timeout

One hard rule: **the script's own limit must be clearly smaller than the DPanel scheduled task's "execution timeout"**.

| Stage | Default | Meaning |
|---|---|---|
| Whole-round hard limit `T_HARD` | 540 seconds | The remaining budget is derived from it; `DP_MIN_UPGRADE` uses it to decide whether there is still time |
| Single check `DP_T_CHECK` | 120 seconds | Squeezed by the remaining budget too — the smaller of the two is used (10 seconds at the minimum) |
| Single upgrade / deploy `DP_T_UPGRADE` | 420 seconds | Same as above |
| DPanel scheduled task "execution timeout" | `600` recommended | It must be larger than `T_HARD`. In the round DPanel SIGKILLs, the log holds nothing but `signal: killed` (the process has no time to flush, and the message is an empty string), so there is nothing to debug with |

## Dependencies

The script runs a dependency self-check before it does anything; if any of them is missing it prints `ERR 缺少依赖命令：xxx` ("ERR: missing dependency command: xxx") and ends with exit code `1`,
instead of blowing up halfway through.

| Command | Purpose | When it is needed |
|---|---|---|
| `timeout` | Puts a timeout on every DPanel call so the whole round cannot be SIGKILLed by the scheduled task's execution timeout | Always |
| `sed` `awk` `grep` | Picking the result JSON out of the DPanel CLI output and stripping the DEBUG noise | Always; the busybox set is enough, the GNU version is not needed |
| `docker` | Using `docker exec` to call the DPanel CLI inside its container, and confirming Docker is reachable | **Only when the script is not inside the dpanel container** |

No longer needed: `curl`, `flock`, `docker buildx` (since v2.0.0 the script neither touches a registry nor pulls images itself, and there is no mutex lock inside it either).

The self-check also calls the DPanel CLI once (`dpanel version`): if no version number comes back it prints `ERR 无法调用 DPanel CLI（<path>）` ("ERR: cannot invoke the DPanel CLI (<path>)") and exits `1`; when not inside the container it also hints at `--dpanel-container` / `--dpanel-bin`. Compose mode additionally requires the project to be registered in DPanel.

## Parameters and environment variables removed in v2.0.0

Pulling, recreating, the health gate, the `:prev` rollback point and the state / transaction directory are all DPanel's job since v2.0.0, so the following invocations **no longer work**. Hitting any of them makes the script **stop immediately**: nothing is changed this time, the exit code is `3`, and the log states which version changed what, why, and the migration path.

### Removed parameters

| Old form | Migration path |
|---|---|
| `--compose-dir` | Delete it. Compose updates are handled by DPanel by project name, so no project directory is needed |
| `--state-dir` | Delete it. The script keeps no state directory any more; the cross-version notice record moved to `COMPAT_ROOT` |
| `--bad-ttl-days` | Delete it. There is no bad-version pinning any more; rollback is DPanel's job |
| `--pull-retries` | Delete it. Pulling is done by DPanel and the script no longer manages pulls and retries |

### Removed environment variables

| Old form | Migration path |
|---|---|
| `STATE_ROOT` | Delete it; the cross-version notice record uses `COMPAT_ROOT` instead (default `/tmp/.container-autoupdate/compat`) |
| `BAD_TTL_DAYS` | Delete it; there is no bad-version pinning or TTL any more, rollback is DPanel's job |
| `PULL_RETRIES` | Delete it; pulling is done by DPanel and the script no longer manages pulls and retries |
| `DIGEST_RETRIES` | Delete it; whether a new version exists remotely is decided by DPanel, the script no longer queries digests itself |
| `DIGEST_RETRY_WAIT` | Delete it; same as above: the remote digest is queried by DPanel |
| `T_STALL` | Delete it; the script no longer reads the Docker pull stream, so stalled-pull detection is gone |
| `T_STALL_FINISH` | Delete it; the finishing grace period of a pull is DPanel's own concern |
| `T_PULL_MAX` | Delete it; pulling is done by DPanel, and on the script side `DP_T_UPGRADE` caps how long a single upgrade call may take |
| `T_UP` | Delete it; container recreation is done by DPanel (`DP_T_UPGRADE` controls how long the script waits) |
| `T_HEALTH` | Delete it; health observation is handled by DPanel's upgrade flow |
| `HEALTH_TRIES` | Delete it; the health gate has been removed and is DPanel's job |
| `T_ROLLBACK` | Delete it; rollback is handled by DPanel's backup mechanism |
| `PLAIN_BOOT` | Delete it; watching containers without a healthcheck is left to DPanel |
| `COMPOSE_DIR` | Delete it; Compose updates are handled by DPanel by project name, so no project directory is needed |
| `COMPOSE_BASE` | Delete it; there is no need to look the Compose directory up from container labels any more |
| `LOCK_PREFIX` | Delete it. The script stopped using a mutex lock in v1.0.0 (concurrency is guaranteed by the DPanel scheduled task), but it stayed in the registry, so setting it today **still stops the run** |

> `T_INSPECT` is **not** on this list: it is the old name, still accepted in v2.0.0 and equivalent to `DP_T_CHECK` (see the table above).
>
> An environment variable must be **non-empty** to be caught (an empty `COMPOSE_DIR=` is not).

A hit looks like this (using `COMPOSE_DIR` as the example):

```text
[2026-11-03 06:00:12] ERR 这个环境变量已经不能用了：COMPOSE_DIR（当前值=/srv/myapp）
[2026-11-03 06:00:12]     从 v2.0.0 起：COMPOSE_DIR 已移除
[2026-11-03 06:00:12]     原因：Compose 更新由 DPanel 按项目名处理，不再需要项目目录
[2026-11-03 06:00:12]     迁移方式：删掉 COMPOSE_DIR 即可，不需要任何替代设置
[2026-11-03 06:00:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-03 06:00:12]     本次未做任何改动，退出码 3
    → ERR: this environment variable can no longer be used: COMPOSE_DIR (current value=/srv/myapp)
    → Since v2.0.0: COMPOSE_DIR has been removed
    → Reason: Compose updates are handled by DPanel by project name, so no project directory is needed
    → Migration path: just delete COMPOSE_DIR, no replacement setting is needed
    → Or pin the download address to the old version (see README "Versions and upgrades")
    → Nothing was changed this time, exit code 3
```

A removed **parameter** prints the same block with parameter wording: the "new form" column of those four entries literally says `删除这个参数`, so the migration line reads `迁移方式：把 --compose-dir 换成 删除这个参数` — the meaning is plain: delete it. (Only the environment-variable branch special-cases that wording; the parameter branch does not.)

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | Success; or already up to date; or `--dry-run` finished checking; or skipped by rule | Nothing to do |
| `1` | A configuration / environment error (no target or two targets, a missing dependency, Docker unreachable, the DPanel CLI not invocable), or the update could not be completed this round (**the container / project is left as it was**) | Look for `ERR` in the log, fix the configuration and run it again |
| `2` | **Reserved**: v2.0.0 never produces it (in the old version it meant "the rollback itself failed"; rollback is DPanel's job now and the script does not see it) | If you do see it, follow the log |
| `3` | **A breaking change was detected**: you used a removed parameter / environment variable, or `--compat` declares a version older than the script (or an invalid value) (nothing was changed this time) | Follow the migration path in the log to fix the command; or pin the download address to the old version; or adjust `--compat` |
| `130` | Interrupted by `SIGINT` (Ctrl-C) | You pressed Ctrl-C during a manual run; no problem |
| `143` | Interrupted by `SIGTERM` / `SIGHUP` (**most common when the scheduled task times out**) | The "execution timeout" is too short: raise it, or lower `T_HARD` |

## Common scenarios and how to configure them

| Scenario | Configuration |
|---|---|
| An ordinary Compose project | `--compose myapp`, everything else default (make sure it is registered in DPanel first) |
| An ordinary `docker run` container | `--container mycontainer`, everything else default |
| After an upgrade the run exits with code `3` right away | The first `ERR` in the log says why: delete that removed parameter / environment variable (`--state-dir`, `STATE_ROOT`, `COMPOSE_DIR` and the like); if you really need the old behaviour, pin the download address to the old version's tag |
| Compose says it is not registered | In DPanel web UI → Compose, create / import that project with the same name the script uses; or switch to `--container <a container of that project>` |
| Running outside the dpanel container | The `docker` command must be present locally; add `--dpanel-container <the real container name>` (default `dpanel`), and `--dpanel-bin <path>` when the path differs; add `--dpanel-docker-env <name>` when the Docker server in DPanel is not called `local` |
| The scheduled task times out (exit code `143`) | First raise the DPanel scheduled task's "execution timeout" above `600` (it must be larger than `T_HARD`); then tune `T_HARD` and `DP_T_UPGRADE` (large images that upgrade slowly) as needed |
| Check calls often time out | Raise `DP_T_CHECK` (default 120) |
| You want to see what would happen first | Add `--dry-run` in container mode; Compose mode has no check-only capability, so try it on a test project |
| You want to see the notice when crossing versions | It is printed by default (the record lives under `COMPAT_ROOT`); if `/tmp` is wiped, move `COMPAT_ROOT` to a persistent directory |
| The script has been upgraded but you want to keep the current behaviour first | `--compat <the version you have verified>`, e.g. `--compat 1.2.3` |
| The scheduled task only shows "exit status 1" and no reason | See [Where the failure reason is written](#where-the-failure-reason-is-written) |

## Where the failure reason is written

The script's output goes to two streams:

- **stdout**: the complete log (including every `ERR` / `CRITICAL` line and its indented follow-up lines).
- **stderr**: **the failure reason only** — the `ERR` / `CRITICAL` lines and the indented follow-up lines right after them.

Why a separate stderr copy: a scheduled task (DPanel) keeps **only stderr** when the task **fails** and discards stdout.
Earlier versions wrote the failure reason to stdout only, so the scheduled task was left with nothing but a bare `exit status 1` and nothing to debug with.
Now the failure reason is written to both streams: the log stays complete, and the scheduled task shows the reason directly.

```
# This is what a failed scheduled task shows (stderr)
[2026-11-03 06:00:12] ERR DPanel 里没有登记名为 myapp 的 Compose 项目
[2026-11-03 06:00:12]     compose:deploy 只能操作 DPanel「Compose」页面里登记过的项目
[2026-11-03 06:00:12]     处理方式二选一：
[2026-11-03 06:00:12]       1) 在 DPanel 网页里新建 Compose 项目，名称填 myapp（指向它的 docker-compose.yaml）
[2026-11-03 06:00:12]       2) 改用容器模式：--container <该项目里的容器名>
[2026-11-03 06:00:12]     项目未做任何改动
    → ERR: DPanel has no Compose project registered under the name myapp
    → compose:deploy can only operate projects registered on DPanel's "Compose" page
    → Two ways to fix it:
    →   1) Create a Compose project in the DPanel web UI with the name myapp (pointing at its docker-compose.yaml)
    →   2) Switch to container mode: --container <a container of that project>
    → The project was not changed at all
```

When you run it by hand both streams land on the terminal, so there is no visible difference; you can also look at them separately:

```sh
sh container-autoupdate.sh --compose myapp >/tmp/ct.out 2>/tmp/ct.err
# /tmp/ct.out holds the complete log, /tmp/ct.err only the failure reason
```

## Bootstrapper (`ct-bootstrap.sh`) parameters and environment variables

The bootstrapper is the recommended way to run it: it takes care of downloading and caching the main script, so you only maintain one command line.
It needs `curl` itself (for probing and downloading) and `sh`; when it runs outside the dpanel container it needs `docker` as well.

Two ways to specify them, in priority order: **command line `--ct-*` > environment variable `CT_*`**.
Bootstrapper options must come before the main script's arguments; you can also use `--` to separate them explicitly.

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
