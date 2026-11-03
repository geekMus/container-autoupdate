# All parameters and environment variables

> Language: [English](parameters.en.md) | [中文](parameters.md)

> From v2.1.0 each mode plays to its own strengths: **containers go to DPanel** (`container:upgrade`, which checks first and only upgrades when a new version really exists), and **Compose projects go to docker's own compose** (`docker compose pull` + `docker compose up -d`, redeploying in place).
> The script itself does three things only: decide whether the target needs updating, hand the update action to whoever performs it, and report the outcome honestly.
> That makes it a tool for a **DPanel scheduled task**: it runs one round and exits, and frequency and concurrency are DPanel's business; one scheduled task per target is enough (the script keeps no internal mutex lock).
> Running it by hand is allowed too, but that is a single run; wrapping it in cron / a systemd timer is not recommended.

## Prerequisites: who performs the update

**Only container mode depends on DPanel.** Compose mode uses nothing but `docker` and the Compose v2 plugin, **never touches DPanel**, and therefore does **not** require the project to be registered in the DPanel web UI first (only v2.0.0's `compose:deploy` required that).

- Container mode: the update capability comes from DPanel's own command line (DPanel 1.11.x ships `container:upgrade`), and the script writes no Docker work of its own (no pull, no tag, no create, no rm).
  - Running it **inside the dpanel container** is the least effort (a DPanel scheduled task executes there by default): the script runs `/app/server/dpanel` directly.
  - It can also run on the host or in another container: the script then uses `docker exec dpanel /app/server/dpanel ...`, which requires the `docker` command; if the container is not called `dpanel`, name it with `--dpanel-container`.
- Compose mode: the script works out the project directory and compose file, then runs `docker compose pull` and `docker compose up -d` in that directory. It requires the `docker` command and the **Compose v2 plugin** (`docker compose`, not `docker-compose`).

The two modes:

| How your container was started | Which parameter | What the script actually runs |
|---|---|---|
| `docker compose up -d` | `--compose <project name>` | `docker compose pull` + `docker compose up -d` (redeploy in place in the project directory) |
| `docker run ...` | `--container <container name>` | `dpanel container:upgrade --name <container name> --docker-env <env name>` (check first without `--upgrade`, and add `--upgrade` only when a new version really exists) |

The directory and files of a Compose project need no configuration by default. The script first finds the containers belonging to the project:

```sh
docker ps -a --filter label=com.docker.compose.project=<project name>
```

then reads three labels off them with `docker inspect`: `com.docker.compose.project.working_dir` (directory), `com.docker.compose.project.config_files` (compose file) and `com.docker.compose.project.environment_file` (env file). Only when that lookup finds nothing (not a single container belongs to the project) does `--compose-dir` / `COMPOSE_DIR` serve as the fallback.

The safety boundary (the rules worth remembering):

- Compose mode uses only compose's own `pull` / `up -d`: no manual tag, no manual create, nothing deleted, and **no `--remove-orphans`** (it deletes containers that are not in the current compose file, which is a data incident).
- compose parameters always travel as environment variables (`COMPOSE_PROJECT_NAME` / `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` / `COMPOSE_ENV_FILES`) and are never joined into a command line — with a path containing spaces, compose prints its Usage and still returns `0` (a silent failure).
- The script never touches a registry: how images are pulled and which mirror is used is decided by the docker daemon / DPanel according to your configuration (no "parallel racing between mirror addresses" is needed).
- The script does not judge whether an image is a bad version: container mode relies on DPanel (which rolls back on its own if the container will not come up), and Compose mode relies on "a failed pull or deploy means no deploy" plus "containers that do not come up are pointed out".
- Health and business correctness are not the script's job: the script only guarantees "the compose command succeeded" + "the containers are running". **Data is not rolled back**, so a production database should still have its own backup.

Rollback points (they differ between the two modes):

- **Container mode**: the rollback point is the **backup container** DPanel creates, named like `<container name>-bak-<timestamp>` (for example `myapp-bak-20261103163808`); it runs the pre-upgrade image and sits in the Exited state. It is visible directly in the DPanel web UI, and restoring from the command line is:

```sh
docker stop <new container> && docker rm <new container>
docker rename <container name>-bak-<timestamp> <container name>
docker start <container name>
```

- **Compose mode: there is no backup container, and no `<repo>:prev` is maintained.** It relies on one property — pulling does not delete old images:

```sh
# the old image id can be read from the previous round's log line "已重建：<name>（old12 → new12）"
docker tag <old image ID> <repo>:latest
docker compose up -d --force-recreate
```

The v1.x `<repo>:prev` tag and the `/tmp/.container-autoupdate/compose-*` transaction directories have not been created since v2.0.0; they can be deleted by hand after upgrading.

## Specifying a target

Exactly one of the two targets **must** be given. Giving both (`--compose a --container b`) fails immediately with exit code `1` instead of letting the last one win silently.

| Parameter | Meaning |
|---|---|
| `--compose <project name>` | The Compose project name, that is the `docker compose` project name (usually the directory name; `docker compose ls` shows it). The directory and compose file are reverse-looked-up from container labels by default |
| `--container <container name>` | The container name, that is `NAMES` in `docker ps` |

Three ways to specify it, in priority order: **command line > environment variable > the configuration block at the top of the script**.

```sh
# 1. command line
container-autoupdate.sh --compose myapp

# 2. environment variable
UPD_COMPOSE=myapp container-autoupdate.sh

# 3. the configuration block at the top of the script (good for a fixed purpose)
COMPOSE_NAME="myapp"
CONTAINER_NAME=""
```

## All command-line parameters

The table corresponds one-to-one with the `case` branches of `parse_args()` (there is also the `*)` catch-all: a writing registered as removed exits with code `3`, and any other unknown parameter reports `ERR 未知参数：<parameter>（用 --help 查看用法）` and ends with exit code `1`).

| Parameter | Default | When you need it |
|---|---|---|
| `--compose <project name>` | none | Required in Compose mode. The directory and compose file are reverse-looked-up from container labels by default (see the previous section) |
| `--container <container name>` | none | Required in container mode |
| `--docker-sock <path>` | empty | When the Docker socket is **not in the default location** (rootless Docker's `/run/user/1000/docker.sock`, a socket mounted at an unusual path). When set, the script does `export DOCKER_HOST=unix://<path>`, which **overrides** `DOCKER_HOST`. Compose mode always needs the docker CLI, so this parameter applies there too |
| `--compose-dir <path>` | empty | The Compose project directory. **Removed in v2.0.0, available again since v2.1.0**: it is only a fallback for when the project directory cannot be reverse-looked-up (no container belongs to the project, or the containers carry no compose labels) |
| `--dpanel-container <name>` | `dpanel` | When you are **not inside the dpanel container** and the DPanel container is called something else (the script calls the DPanel CLI via `docker exec <name> ...`). Used by container mode only |
| `--dpanel-bin <path>` | `/app/server/dpanel` | When the DPanel CLI lives at a different path inside the container. Note: the script decides whether it is already inside the DPanel container by testing whether this path (from the configuration block / `DPANEL_BIN`) is executable, and that decision is made **before** the command line is parsed, so `--dpanel-bin` only changes which binary is called, not that decision. Used by container mode only |
| `--dpanel-docker-env <name>` | `local` | When the Docker server in your DPanel is not called `local` (it matches the environment name under "Docker servers" in DPanel). Used by container mode only |
| `--compat <version>` | off | **Declares "I have only verified up to this version".** If the script is newer and a registered breaking change lies in between, it stops hard instead of taking the risk; a malformed value (such as `1..2`), an empty value, or a version newer than the script also aborts (exit code `3`) |
| `--dry-run` | off | Check only, take no action, and **the two modes behave differently** (see below). Use it when onboarding a target or investigating "why was nothing updated" |
| `-h` / `--help` | — | Show help, exit code `0` |
| `-V` / `--version` | — | Show the version number, exit code `0` |

Any parameter that takes a value reports `ERR <parameter> 缺少参数` and exits `1` when the value is missing.

### What `--dry-run` does in each mode

| Mode | What the script actually does | Exit code |
|---|---|---|
| Container | Calls DPanel's check (that is `container:upgrade` without `--upgrade`): when a new version exists it prints `发现新版本（远端 digest=…）` and `DRY 只检查不动手，本轮不升级`, does **not** upgrade, and leaves the container untouched; when it is already the latest it prints `OK 容器 <名> 已是最新（DPanel 报告 status=latest）` | `0` |
| Compose | Locates the project first, lists the images the project involves with `docker compose config --images`, then prints the two `DRY` lines; it does **not** pull or deploy, leaving the project untouched | `0` |

Container mode:

```text
[2026-11-03 06:00:12] MODE container 容器=myapp
[2026-11-03 06:00:12] 发现新版本（远端 digest=sha256:a5c10db1...）
[2026-11-03 06:00:12] DRY 只检查不动手，本轮不升级
    → MODE container container=myapp
    → a new version was found (remote digest=sha256:a5c10db1...)
    → DRY check only, no action this round; not upgrading
```

Compose mode:

```text
[2026-11-03 06:00:12] MODE compose 项目=myapp
[2026-11-03 06:00:12]     目录=/srv/myapp
[2026-11-03 06:00:12]     文件=/srv/myapp/docker-compose.yml
[2026-11-03 06:00:12]     镜像: ghcr.1ms.run/yetone/magpie:latest
[2026-11-03 06:00:12] DRY 只检查不动手：上面是这个项目涉及的镜像，本轮不拉取、不部署
[2026-11-03 06:00:12]     要真正更新就去掉 --dry-run（拉取本身就是「有没有新版本」的判断）
    → MODE compose project=myapp
    →     directory=/srv/myapp
    →     file=/srv/myapp/docker-compose.yml
    →     image: ghcr.1ms.run/yetone/magpie:latest
    → DRY check only, no action: the lines above are the images this project involves; nothing is pulled or deployed this round
    →     to really update, drop --dry-run (pulling is itself the "is there a new version" test)
```

> The meaning of `--dry-run` really does differ between the modes: container mode **genuinely asks DPanel** whether a new version exists, while Compose mode only **lists the images this project involves** — compose has no "check whether a new version exists" capability, and pulling is itself that test.
>
> `--dry-run` in Compose mode still has to locate the project first: when the directory cannot be reverse-looked-up and no `--compose-dir` is given, it fails immediately with exit code `1`.

## All environment variables

Command line > environment variable > configuration block; the first two are exactly equivalent to their same-named parameters.

| Variable | Corresponding parameter | Default | When you need it |
|---|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | `--compose` / `--container` | empty | Set in DPanel's Environment panel, or to serve several targets from one command |
| `DOCKER_SOCK` | `--docker-sock` | empty | As above; when set, the script does `export DOCKER_HOST=unix://$DOCKER_SOCK` (overriding `DOCKER_HOST`) |
| `DOCKER_HOST` | — | docker CLI's own default | The docker CLI's standard variable; the script does not override it. Both `unix:///path` and `tcp://host:port` work |
| `DPANEL_NAME` | `--dpanel-container` | `dpanel` | Container mode: the DPanel container name |
| `DPANEL_BIN` | `--dpanel-bin` | `/app/server/dpanel` | Container mode: the DPanel CLI path inside the container; it also takes part in the "am I already inside the DPanel container" decision |
| `DPANEL_DOCKER_ENV` | `--dpanel-docker-env` | `local` | Container mode: the docker environment name inside DPanel |
| `COMPOSE_DIR` | `--compose-dir` | empty | **Removed in v2.0.0, available again since v2.1.0**: fallback when the project directory cannot be reverse-looked-up |
| `COMPAT_ROOT` | — | `/tmp/.container-autoupdate/compat` | Where cross-version notices are recorded (one subdirectory per target, holding `lastver`). Change it to a persistent directory when `/tmp` is cleared on reboot or the record must live longer |
| `COMPAT_UNTIL` | `--compat` | empty | As above |
| `DRY_RUN` | `--dry-run` | `0` | Setting `1` is equivalent to `--dry-run` |
| `T_HARD` | — | `540` | The hard per-round time limit (seconds). Lower it when the scheduled task's "execution timeout" is shorter |
| `DP_T_CHECK` | — | `120` | Timeout in seconds for a single "check" call: Compose mode's `docker compose config --images`, the DPanel CLI `version` self-check, and container mode's check call. Raise it when DPanel / compose responds slowly |
| `T_INSPECT` | — | empty | **The old name, still accepted**: used as the default for `DP_T_CHECK` only when `DP_T_CHECK` is unset, so it is equivalent; when both are set, `DP_T_CHECK` wins |
| `DP_T_UPGRADE` | — | `420` | Timeout in seconds for a single **container upgrade** call (`container:upgrade --upgrade`); it is in practice also clamped by the remaining budget (computed from `T_HARD`) |
| `DP_T_PULL` | — | `420` | **New in v2.1.0**: timeout in seconds for a single `docker compose pull` in Compose mode; likewise clamped by the remaining budget |
| `DP_T_UP` | — | `180` | **New in v2.1.0**: timeout in seconds for a single `docker compose up -d` in Compose mode; likewise clamped by the remaining budget |
| `DP_MIN_UPGRADE` | — | `90` | Below this remaining budget the script takes no action, so the scheduled task cannot kill it halfway; both a container upgrade and a Compose deployment (pull + redeploy) are bound by it |

## Time budget and the scheduled task timeout

One hard rule: **the script's own limits must be clearly shorter than the DPanel scheduled task's "execution timeout"**.
Every call is additionally clamped to the remaining budget (10 seconds at the minimum): the effective timeout is the smaller of the configured value and the remaining time.

| Stage | Default | Notes |
|---|---|---|
| Whole-round hard limit `T_HARD` | 540 seconds | The remaining budget is computed from it, and `DP_MIN_UPGRADE` uses it to decide "is there still time" |
| Single check `DP_T_CHECK` | 120 seconds | Container mode's check call, the DPanel CLI `version` self-check, and Compose mode's `docker compose config --images` |
| Single container upgrade `DP_T_UPGRADE` | 420 seconds | The real upgrade call in container mode |
| Compose pull `DP_T_PULL` | 420 seconds | Compose mode's `docker compose pull` |
| Compose redeploy `DP_T_UP` | 180 seconds | Compose mode's `docker compose up -d` |
| Remaining-budget gate `DP_MIN_UPGRADE` | 90 seconds | Below this remaining time the script takes no action: both a container upgrade and a Compose deployment back off early and report honestly (exit code `1`) |
| The DPanel scheduled task's "execution timeout" | `600` recommended | It must exceed `T_HARD`. In a round killed by DPanel's SIGKILL the log holds nothing but `signal: killed` (the process had no time to flush, and the message is an empty string), so nothing can be investigated |

## Dependencies

The script self-checks before acting and reports whatever is missing and exits with code `1`, rather than blowing up halfway through.

| Command / program | Purpose | When it is needed |
|---|---|---|
| `timeout` | Puts a timeout around every docker / DPanel call so the scheduled task's execution timeout cannot SIGKILL the whole round | Always |
| `sed` `awk` `grep` | Picks the result JSON out of the DPanel CLI output and strips the DEBUG noise; de-duplicates `docker compose config --images` | Always; the busybox versions are enough, no GNU builds required |
| `docker` | Compose mode runs `docker compose` / `docker ps` / `docker inspect`; container mode uses `docker exec` to reach the DPanel container | Always in Compose mode; in container mode **only when "not inside the dpanel container"** |
| The Compose v2 plugin (`docker compose`) | Compose mode's real update actions (`pull` / `up -d`) | **Compose mode only** |
| The DPanel CLI (`/app/server/dpanel` by default) | Container mode's check and upgrade | **Container mode only** |

No longer needed: `curl`, `flock`, `docker buildx` (the script touches no registry of its own and implements no mutex lock).

The self-check says which kind of problem it hit:

```text
ERR 缺少依赖命令： docker
    需要 timeout 与 busybox 或 coreutils 基础工具；
    Compose 模式还需要 docker（含 docker compose 插件）；不在 DPanel 容器里跑时也需要 docker

ERR 无法连接 Docker（DOCKER_HOST=未设置）
    请确认 Docker 正在运行，且当前用户有权限访问 socket

ERR 无法执行 docker compose（缺 compose 插件？）
    Compose 模式需要 Docker Compose v2 插件版（docker compose，不是 docker-compose）
    → ERR missing dependency command: docker
    →     requires timeout and the busybox or coreutils base tools;
    →     Compose mode also needs docker (with the docker compose plugin); docker is also needed when not running inside the DPanel container
    → ERR cannot connect to Docker (DOCKER_HOST=not set)
    →     make sure Docker is running and the current user may access the socket
    → ERR cannot run docker compose (missing the compose plugin?)
    →     Compose mode needs the Docker Compose v2 plugin release (docker compose, not docker-compose)
```

Container mode's self-check additionally calls the DPanel CLI once (`dpanel version`): if no version number comes back it reports `ERR 无法调用 DPanel CLI（<path>）` and exits `1`; outside the container it also gives `已尝试：docker exec <DPANEL_NAME> <DPANEL_BIN> version` and points at `--dpanel-container` / `--dpanel-bin`. **Compose mode does not do this step.**

## Removed parameters and environment variables (aborted on sight, exit code 3)

Pulling on its own, recreating containers, the health gate, the `:prev` rollback point and the state / transaction directories are no longer part of the script, so the writings below **no longer work**. Hitting any of them makes the script **stop at once**: nothing is changed this round, the exit code is `3`, and the log gives "since which version this changed / why / the migration path".

### Removed parameters

| Old writing | Migration path |
|---|---|
| `--state-dir` | Delete it. The script no longer maintains a state directory; the cross-version notice record moved to `COMPAT_ROOT` |
| `--bad-ttl-days` | Delete it. There is no "bad version pinning" any more; rollback belongs to whoever performs the update (a DPanel backup container in container mode, a local old image in Compose mode) |
| `--pull-retries` | Delete it. Container mode's pull is done by DPanel and Compose mode's pull by `docker compose pull`; the script no longer manages pulling and retries (the timeouts are `DP_T_UPGRADE` / `DP_T_PULL`) |

> `--compose-dir` is **not** on this list: it was removed in v2.0.0 and became **available again in v2.1.0** (see the parameter table above).

### Removed environment variables

| Old writing | Migration path |
|---|---|
| `STATE_ROOT` | Delete it; the cross-version notice record now uses `COMPAT_ROOT` (`/tmp/.container-autoupdate/compat` by default) |
| `BAD_TTL_DAYS` | Delete it; there is no "bad version pinning" or TTL any more, and rollback belongs to whoever performs the update |
| `PULL_RETRIES` | Delete it; pulling is done by the performer (DPanel in container mode, `docker compose pull` in Compose mode) and the script no longer manages pulls and retries |
| `DIGEST_RETRIES` | Delete it; whether a new version exists remotely is judged by the performer and the script no longer looks up digests itself |
| `DIGEST_RETRY_WAIT` | Delete it; as above — the remote digest is no longer queried by the script |
| `T_STALL` | Delete it; the script no longer reads the Docker pull stream and the pull-stall decision is gone |
| `T_STALL_FINISH` | Delete it; the pull finishing grace period is no longer handled by the script |
| `T_PULL_MAX` | Delete it; pulling goes to the performer and the script's side can bound a single call's duration with `DP_T_PULL` / `DP_T_UPGRADE` |
| `T_UP` | Delete it; container recreation is done by DPanel (`DP_T_UPGRADE` controls how long the script waits); Compose mode's redeploy uses `DP_T_UP` |
| `T_HEALTH` | Delete it; health observation is the performer's job |
| `HEALTH_TRIES` | Delete it; the health gate is gone |
| `T_ROLLBACK` | Delete it; rollback is the performer's job (DPanel's backup mechanism in container mode) |
| `PLAIN_BOOT` | Delete it; the observation of containers without a healthcheck is gone |
| `COMPOSE_BASE` | Delete it; the base path for reverse-looking-up a Compose directory from container labels is no longer needed (the lookup uses the labels compose itself writes on the containers) |
| `LOCK_PREFIX` | Delete it. The script stopped using a mutex lock in v1.0.0 (concurrency is guaranteed by the DPanel scheduled task), but the entry stayed in the registry, so setting it today **still trips the stop** |

> `T_INSPECT` is **not** on this list: it is the old name, still accepted, equivalent to `DP_T_CHECK` (see the table above).
>
> `COMPOSE_DIR` is **not** on this list either: it was removed in v2.0.0 and became **available again in v2.1.0**, equivalent to `--compose-dir`.
>
> An environment variable must be **non-empty** to trip the check (an empty value such as `STATE_ROOT=` does not count).

The log when it trips looks like this (`STATE_ROOT` as the example):

```text
[2026-11-03 06:00:12] ERR 这个环境变量已经不能用了：STATE_ROOT（当前值=/tmp/ct-state）
[2026-11-03 06:00:12]     从 v2.0.0 起：STATE_ROOT 已移除
[2026-11-03 06:00:12]     原因：2.0.0 起脚本不再维护状态目录；跨版本提示记录改到 COMPAT_ROOT（默认 /tmp/.container-autoupdate/compat）
[2026-11-03 06:00:12]     迁移方式：删掉 STATE_ROOT 即可，不需要任何替代设置
[2026-11-03 06:00:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-03 06:00:12]     本次未做任何改动，退出码 3
    → ERR this environment variable no longer works: STATE_ROOT (current value=/tmp/ct-state)
    →     since v2.0.0: STATE_ROOT has been removed
    →     reason: from 2.0.0 the script no longer maintains a state directory; the cross-version notice record moved to COMPAT_ROOT (/tmp/.container-autoupdate/compat by default)
    →     migration path: just delete STATE_ROOT, no replacement setting is needed
    →     alternatively, pin the download address to the old version (see "Versions and upgrades" in the README)
    →     nothing was changed this round, exit code 3
```

A removed **parameter** trips the same sentences with only the name swapped. Note that the "new form" of these entries in `BREAKING_TABLE` is the literal `删除这个参数` / `删除这个环境变量`, so the script does **not** print the message `replace X with 删除这个参数`; it says straight out "just delete X, no replacement setting is needed":

```text
[2026-11-03 06:00:12] ERR 这个参数已经不能用了：--state-dir
[2026-11-03 06:00:12]     从 v2.0.0 起：--state-dir 已移除
[2026-11-03 06:00:12]     原因：2.0.0 起脚本不再维护状态目录；跨版本提示记录改到 COMPAT_ROOT
[2026-11-03 06:00:12]     迁移方式：删掉 --state-dir 即可，不需要任何替代设置
[2026-11-03 06:00:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-03 06:00:12]     本次未做任何改动，退出码 3
    → ERR this parameter no longer works: --state-dir
    →     since v2.0.0: --state-dir has been removed
    →     reason: from 2.0.0 the script no longer maintains a state directory; the cross-version notice record moved to COMPAT_ROOT
    →     migration path: just delete --state-dir, no replacement setting is needed
    →     alternatively, pin the download address to the old version (see "Versions and upgrades" in the README)
    →     nothing was changed this round, exit code 3
```

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | Success; or already the latest (container mode) / "no container needed recreating after the pull" (Compose mode); or `--dry-run` finished its check; `-h` / `--help` and `-V` / `--version` also return it | Nothing to do |
| `1` | A configuration / environment error (no target or two targets, a missing dependency, cannot connect to Docker, no Compose v2 plugin, cannot call the DPanel CLI, cannot work out the Compose project directory), or the round could not finish the update (**the container / project is left as it was**) | Read the `ERR` in the log, fix it and run again |
| `2` | **Reserved**: the current version never produces it (old versions meant "rollback failed"; container rollback now belongs to DPanel, and a failed in-place Compose redeploy means the script does not deploy, so no half-new project is left behind) | If you ever see it, follow the log |
| `3` | **A breaking change was detected**: a removed parameter / environment variable was used, or `--compat` declares an older version than the script (or its value is malformed / empty) (nothing was changed this round) | Change the command as the log's "migration path" says; or pin the download address to the old version; or adjust `--compat` |
| `130` | Interrupted by `SIGINT` (Ctrl-C) | You pressed Ctrl-C during a manual run; harmless |
| `143` | Interrupted by `SIGTERM` / `SIGHUP` (**most often the scheduled task's execution timeout**) | The "execution timeout" is too short: raise it, or lower `T_HARD` |

## Common scenarios and how to configure them

| Scenario | Configuration |
|---|---|
| An ordinary Compose project | `--compose myapp`, everything else at its default. The project directory is reverse-looked-up from container labels automatically and usually needs no configuration |
| The Compose project directory cannot be reverse-looked-up | Add `--compose-dir <path>` (or set `COMPOSE_DIR`); alternatively run `docker compose up -d` by hand once so compose's labels land on the containers |
| An ordinary `docker run` container | `--container mycontainer`, everything else at its default |
| Compose mode on a machine without DPanel | Nothing to install: Compose mode only needs `docker` and the Compose v2 plugin |
| After upgrading, it exits with code `3` right away | The first `ERR` in the log is the reason: delete that removed parameter / environment variable (`--state-dir`, `STATE_ROOT` and the like). `--compose-dir` / `COMPOSE_DIR` are **not** on that list; to keep the old behaviour instead, pin the download address to the old version's tag |
| A Compose container will not come up | The script reports `ERR 有容器没在运行（R/M running）：` and lists the containers that are not running, exit code `1`; use `docker compose logs <service name>` to see why |
| Running outside the dpanel container (container mode) | The machine needs `docker`; use `--dpanel-container <actual container name>` (default `dpanel`), add `--dpanel-bin <path>` if the path differs, and add `--dpanel-docker-env <name>` if the Docker server in DPanel is not called `local` |
| The scheduled task times out (exit code `143`) | First raise the DPanel scheduled task's "execution timeout" above `600` (it must exceed `T_HARD`); then tune `T_HARD`, `DP_T_UPGRADE` (slow container upgrades) or `DP_T_PULL` / `DP_T_UP` (slow Compose pulls / redeploys) as needed |
| Check calls often time out | Raise `DP_T_CHECK` (120 by default) |
| Compose pulls often time out | Raise `DP_T_PULL` (420 by default) |
| Compose redeploys often time out | Raise `DP_T_UP` (180 by default) |
| You want to see what it would do first | In container mode add `--dry-run` (it genuinely asks DPanel whether a new version exists); in Compose mode add `--dry-run` (it only lists the images the project involves, pulling and deploying nothing) |
| You want to see the notice on a cross-version jump | It is printed by default (the record lives under `COMPAT_ROOT`); if `/tmp` gets cleared, point `COMPAT_ROOT` at a persistent directory |
| The script has upgraded but you want the current behaviour to stay put | `--compat <the version you verified>`, for example `--compat 1.2.3` |
| The scheduled task shows nothing but "exit status 1" | See [Where the failure reason is written](#where-the-failure-reason-is-written) |

## Where the failure reason is written

The script's output goes two ways:

- **stdout**: the full log (including every `ERR` / `CRITICAL` and its indented follow-up lines).
- **stderr**: **only the failure reason** — the `ERR` / `CRITICAL` lines and the indented follow-up lines right after them.

Why a separate stderr: a scheduled task (DPanel) keeps only stderr and discards stdout when the task **fails**.
Early versions wrote the failure reason to stdout alone, so the scheduled task kept a bare `exit status 1` and nothing could be investigated.
The failure reason is now written both ways: the log stays complete, and the scheduled task still sees the reason when the run fails.

```text
[2026-11-03 06:00:12] ERR 找不到 Compose 项目 myapp 的项目目录
[2026-11-03 06:00:12]     当前 Docker 里没有带「myapp」这个 compose 项目标签的容器，反查不到
[2026-11-03 06:00:12]     处理方式二选一：
[2026-11-03 06:00:12]       1) 用 --compose-dir <路径> 指定 compose 文件所在目录
[2026-11-03 06:00:12]       2) 确认项目名写法；项目还没部署过就先手动 compose up 一次
    → ERR cannot find the project directory of Compose project myapp
    →     no container in the current Docker carries the "myapp" compose project label, so the lookup failed
    →     two ways to handle it:
    →       1) point --compose-dir <path> at the directory holding the compose file
    →       2) check how the project name is written; if the project has never been deployed, run compose up by hand once
```

A failed update action in Compose mode is written the same way (with compose's own words appended, at most 5 lines):

```text
[2026-11-03 06:00:12] ERR 拉取失败（docker compose pull 退出码 1），本轮不部署，项目保持原样
[2026-11-03 06:00:12]     <compose 输出的最后 5 行>
    → ERR the pull failed (docker compose pull exit code 1); nothing is deployed this round and the project stays as it was
    →     <the last 5 lines of compose's output>
```

During a manual run both streams land in the terminal and look alike; you can also separate them yourself:

```sh
sh container-autoupdate.sh --compose myapp >/tmp/ct.out 2>/tmp/ct.err
# /tmp/ct.out is the full log, /tmp/ct.err holds only the failure reason
```

## The bootstrapper (retired in v3.0.0)

Earlier versions shipped a bootstrapper, `ct-bootstrap.sh`, that downloaded and cached the main script. It is gone as of v3.0.0: the whole script is under 50KB, and "download → verify → run" right inside the scheduled task is enough — caching and version probing bought nothing.

Nine environment variables retired with it (`CT_VERSION`, `CT_CACHE_DIR`, `CT_CACHE_KEEP`, `CT_SOURCE`, `CT_T_NET`, `CT_TRIES`, `CT_PROBE_BYTES`, `CT_FORCE`, `CT_QUIET`), together with every `--ct-*` argument. If one is still in the task, the script stops immediately (exit code `3`) and prints the migration path; the new shape is in [Quick start](../README.en.md#quick-start), and pinning a version means using a tag-qualified download URL.
