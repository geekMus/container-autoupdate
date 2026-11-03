# Advanced usage

> Language: [English](advanced-usage.en.md) | [中文](advanced-usage.md)

> For the basic usage see the [README](../README.en.md); all arguments are in the [parameter reference](parameters.en.md).
>
> As of v2.0.0 the script **no longer pulls images or recreates containers itself**: it only decides whether an update is needed, hands the update over to DPanel's command line
> (containers via `container:upgrade`, Compose projects via `compose:deploy`), and reports the result faithfully. See [How it works and safety boundaries](how-it-works.en.md) for the mechanics.
>
> So this page covers: how to configure the DPanel scheduled task, exit codes, breaking changes and migration, how to roll back, and how to clean up leftovers from before the upgrade.

## 1. DPanel scheduled task

### Two lines in the script box

Create a scheduled task and put **two lines** in the script box:

```sh
# Line 1: fetch the bootstrapper to a local file (it has its own cache, so the same version is not downloaded twice)
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
# Line 2: run one round. Replace --compose with your project name; use --container <name> for a plain container
sh /tmp/ct-bootstrap.sh --compose myapp
```

- Do not write `curl ... | sh`: with a pipe a failed download **silently succeeds** (the task log cannot show that this round did nothing). The bootstrapper writes the file first and executes it only after validation, so a failure returns non-zero explicitly.
- To pin a version in production, add `--ct-version <version>` to the bootstrapper (or set `CT_VERSION`; the version numbers are on the [Releases](https://github.com/geekMus/container-autoupdate/releases) page) — it then stops probing the remote and never goes online. See the [parameter reference](parameters.en.md) for every bootstrapper switch.
- The two modes:

| How your container was started | Which argument | What the script actually runs |
|---|---|---|
| `docker compose up -d` | `--compose <project>` | `dpanel compose:deploy --name <project> --pull-image dpanel` |
| `docker run ...` | `--container <name>` | `dpanel container:upgrade --name <name>` (first without `--upgrade` to check, and only then with it) |

The Compose project must already be **registered in DPanel** (DPanel web UI → Compose → create / import). If it is not, DPanel answers `commonDataNotFoundOrDeleted`; see section 7.

### Set the execution timeout to ≥ 600 seconds

- The script's own hard limit for a round is `T_HARD` (540 seconds by default). DPanel's "execution timeout" must be **clearly larger**, so use **≥ 600 seconds**.
- The timeout of a single call is controlled separately: `DP_T_CHECK` (the check, 120 seconds by default) and `DP_T_UPGRADE` (the upgrade / deploy, 420 seconds by default); every call is additionally narrowed to the remaining budget.
- If the timeout is too short, the round is killed by DPanel and ends with exit code `143`; a round that was SIGKILLed may leave only `signal: killed` in the log, with no reason visible at all.
- When DPanel edits a task in the UI it rewrites the task's settings JSON, and the "execution timeout" you typed by hand can be dropped (measured). After changing the schedule, come back and check it once.
- When less than `DP_MIN_UPGRADE` (90 seconds by default) of the budget is left, the script **does not act**: it reports the failure honestly and exits with `1`, and the next round retries.

### One scheduled task per target

The script takes **no mutex lock** internally; concurrency is guaranteed by the DPanel scheduled task. Two rounds for the same target at the same time step on each other, so **one scheduled task per target**.

Different targets do not affect each other and can each have their own task (see section 7).

### Seeing the reason when it fails

A DPanel scheduled task **keeps only stderr when the task fails** (and only stdout when it succeeds). That is why the script writes the failure reason (the `ERR` / `CRITICAL` lines and the indented continuation lines right after them) to **both** stdout and the real stderr — a design from v1.1.2, kept in v2.0.0. A failed task then shows the reason directly instead of a bare `exit status 1`.

> Side effect: when you merge stdout and stderr into one file by hand, the error lines appear twice.

### Running one round manually

That is allowed, but it is only a **one-off run**:

```sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

### cron / systemd timer are not recommended

The script contains no scheduling and takes no mutex lock. If you run it on a schedule with cron or a systemd timer, **you have to guarantee yourself that two rounds for the same target never run at the same time**. For scheduled updates, use a DPanel scheduled task.
(If you really insist on cron, stagger the times in the crontab expression.)

### The script never touches the registry

Every image pull is done by DPanel / the Docker daemon, using **the registry mirrors you and the daemon configured**. The script never touches a registry, so "racing several image mirror addresses in parallel" is no longer needed under v2.0.0 — and was never implemented (it was evaluated historically).

## 2. Exit codes

| Exit code | Meaning | What to do |
|---|---|---|
| `0` | Successful update / already up to date / `--dry-run` check only | Nothing to do |
| `1` | Failure: DPanel reported an error, the Compose project is not registered in DPanel, not enough time was left, a dependency is missing, or an argument is wrong (**the target is left as it was**) | Look at the `ERR` in the log; the script has not modified the target |
| `2` | **Reserved**: v2.0.0 does not produce it (rollback is DPanel's job; the script cannot see it) | — |
| `3` | **A breaking change was detected** and your invocation no longer works (nothing was changed this round) | Change the command following the "migration path" in the log; or pin a version; or add `--compat` |
| `130` | Interrupted by Ctrl-C (`SIGINT`) | You pressed Ctrl-C on a manual run; harmless |
| `143` | Interrupted by `SIGTERM` / `SIGHUP` (the usual case is a scheduled task timing out) | The "execution timeout" is too short; raise it, or lower `T_HARD` |

## 3. Compatibility mechanisms

Breaking changes (arguments / environment variables / behaviour) are registered in the script's `BREAKING_TABLE`. Following `latest` is still safe, thanks to the three mechanisms below.

### An old form is matched: abort immediately (exit code 3)

An old argument or old environment variable still in use makes the script **abort immediately** with exit code `3`, stating which form no longer works, what it became and from which version, and how to change it:

```text
[2026-11-01 03:47:12] ERR 这个环境变量已经不能用了：LOCK_PREFIX（当前值=/tmp/.container-autoupdate）
[2026-11-01 03:47:12]     从 v1.0.0 起：LOCK_PREFIX 已移除
[2026-11-01 03:47:12]     原因：1.0.0 起脚本不再使用互斥锁，并发由 DPanel 计划任务保证
[2026-11-01 03:47:12]     迁移方式：删掉 LOCK_PREFIX 即可，不需要任何替代设置
[2026-11-01 03:47:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-01 03:47:12]     本次未做任何改动，退出码 3

→ ERR: this environment variable can no longer be used: LOCK_PREFIX (current value=/tmp/.container-autoupdate)
→     as of v1.0.0: LOCK_PREFIX has been removed
→     reason: since 1.0.0 the script no longer uses a mutex lock; concurrency is guaranteed by the DPanel scheduled task
→     migration path: just delete LOCK_PREFIX, no replacement setting is needed
→     or pin the download URL to an old version (see "Versions and upgrades" in the README)
→     nothing was changed this round; exit code 3
```

The arguments and environment variables removed in v2.0.0 are listed in section 4.

### Cross-version notice

The script remembers **the version each target last ran with** (kept under `COMPAT_ROOT`, one `lastver` per target; `/tmp/.container-autoupdate/compat/compose-<project>/lastver` by default, or `container-<name>` in container mode). When it upgrades to a version with a breaking change, the log gets a `WARN` block explaining what changed and what to do, and then **carries on**:

```text
[2026-11-01 03:52:03] WARN 你从 1.0.0 之前的版本(0.9.0)升级上来，v1.0.0 引入了破坏性变更
[2026-11-01 03:52:03]      变更：1.0.0 起移除脚本内的互斥锁：v0.4.0 的锁会被残留的子进程长期占住，导致之后每一轮都跳过
[2026-11-01 03:52:03]      应对：同一目标只挂一个 DPanel 计划任务
[2026-11-01 03:52:03]      本次仍会继续执行。两条路选一条：
[2026-11-01 03:52:03]        1) 接受上面的新做法（想让下一次破坏性变更前先停住，可加 --compat 1.0.0）
[2026-11-01 03:52:03]        2) 想继续用旧行为，把下载地址固定到 v0.9.0 那个 tag

→ WARN: you upgraded from a version before 1.0.0 (0.9.0); v1.0.0 introduced a breaking change
→       change: since 1.0.0 the mutex lock inside the script is gone: the v0.4.0 lock could be held for a long time by a leftover child process, so every later round was skipped
→       how to deal with it: put only one DPanel scheduled task on each target
→       this round still continues. Pick one of the two paths:
→        1) accept the new behaviour above (to stop before the next breaking change, add --compat 1.0.0)
→        2) keep the old behaviour and pin the download URL to the v0.9.0 tag
```

It does **not abort** (it cannot know whether you depend on the old behaviour), it only notifies. The same version is not announced twice, and a downgrade is not announced at all.

> Note: **do not put the old version number from the notice into `--compat`** (in the example that is `0.9.0`) — `--compat` means "I have verified up to vX", so a version older than the change declares "I have not verified this change" on every single run and therefore **stops hard every time** (exit code `3`).
> To "stop before the change" you should write **the current script version** (`sh container-autoupdate.sh --version` prints it; the log's first line `container-autoupdate v<version> 启动` carries it as well).

### `--compat <version>`

It declares "I have only verified up to this version". If the script is newer and a registered `behavior` change lies in between, it **stops hard** with exit code `3`:

```sh
container-autoupdate.sh --compose myapp --compat 1.2.3
```

(`1.2.3` is an example placeholder — replace it with the version you **verified**.)

It suits the case where you verified a version in production, the script one day jumps to a release with a breaking change, and you have no time for a regression: `--compat` then means "do not touch my container when you hit a breaking change I have not verified". Once you have verified, change the number to the new version or drop the option.

Boundary behaviour:

| Case | Result |
|---|---|
| `--compat` is given no value | exit code `1` (argument error: missing value) |
| An invalid value (`abc`, `1..2`), or an explicitly empty value | exit code `3` |
| A value newer than the script (usually a wrong download URL) | exit code `3` |
| A value equal to or higher than the change version | let it pass |
| No breaking change is registered at all | let it pass, no bother |

> The ordering is deliberate: the compatibility checks run **before** the dependency check (a machine without `docker` must still see the migration path first); the cross-version `WARN` is printed before the dependency check too, but `lastver` is written **after** it — a round that failed on a missing dependency does not count as "the user has been told".

## 4. Migrating from v1.x

### Removed arguments

These four arguments are **gone** in v2.0.0: passing one makes the script abort at once with exit code `3` and print the migration path.

| Removed argument | What it used to do | What to do now |
|---|---|---|
| `--compose-dir` | Told the script the Compose project directory | Not needed: DPanel handles the update by **project name** and knows the project directory itself |
| `--state-dir` | Set the state directory | Not needed: the cross-version record moved to `COMPAT_ROOT` (`/tmp/.container-autoupdate/compat` by default) |
| `--bad-ttl-days` | Bad-version pinning period | Not needed: there is no bad-version pinning any more; rollback is DPanel's job |
| `--pull-retries` | Pull retry count | Not needed: DPanel performs the pull; the script no longer manages pulls or retries |

### Removed environment variables

These environment variables are gone in v2.0.0 (still setting one aborts with exit code `3`); the migration path is always to **delete it**, with no replacement:

| Variable | What it used to do |
|---|---|
| `STATE_ROOT` | State directory |
| `BAD_TTL_DAYS` | Bad-version pinning period (days) |
| `PULL_RETRIES` | Pull retry count |
| `DIGEST_RETRIES` | Retries when the remote digest could not be read |
| `DIGEST_RETRY_WAIT` | Wait between remote digest retries |
| `T_STALL` | Stall detection for the pull progress |
| `T_STALL_FINISH` | Grace period while the pull finished |
| `T_PULL_MAX` | Absolute limit for a single pull |
| `T_UP` | Timeout for recreating / starting the container |
| `T_HEALTH` | Wall-clock limit of the health gate |
| `HEALTH_TRIES` | Poll-count limit of the health check |
| `T_ROLLBACK` | Timeout of the rollback |
| `PLAIN_BOOT` | Observation window for a container without a healthcheck |
| `COMPOSE_DIR` | Compose project directory |
| `COMPOSE_BASE` | Fallback root for the Compose directory |

> One exception: `T_INSPECT` **is still accepted** and is equivalent to `DP_T_CHECK`, so old tasks keep working without a config change.

### `LOCK_PREFIX` still aborts

`LOCK_PREFIX` belongs to the earlier 1.0.0 breaking change (the mutex lock inside the script was removed) and is still in `BREAKING_TABLE`. A leftover `LOCK_PREFIX=...` in the start command still aborts the script with exit code `3`; just delete it.

### New arguments and environment variables

| Argument | Environment variable | Default | Notes |
|---|---|---|---|
| `--dpanel-container <name>` | `DPANEL_NAME` | `dpanel` | Name of the container DPanel runs in (used only when the script does not run inside the dpanel container) |
| `--dpanel-bin <path>` | `DPANEL_BIN` | `/app/server/dpanel` | Path of the DPanel CLI |
| `--dpanel-docker-env <name>` | `DPANEL_DOCKER_ENV` | `local` | `--docker-env` passed to the DPanel CLI |

| Variable | Default | Notes |
|---|---|---|
| `COMPAT_ROOT` | `/tmp/.container-autoupdate/compat` | Directory of the cross-version records (one `lastver` per target) |
| `T_HARD` | `540` | Hard limit for the whole round (seconds) |
| `DP_T_CHECK` | `120` | Timeout of one "check" call (seconds); the old `T_INSPECT` is still accepted |
| `DP_T_UPGRADE` | `420` | Timeout of one "upgrade / deploy" call (seconds) |
| `DP_MIN_UPGRADE` | `90` | Below this much remaining budget the script does not act (seconds) |

Retained arguments: `--compose`, `--container`, `--docker-sock`, `--compat`, `--dry-run`, `-h` / `--help`, `-V` / `--version`. See the [parameter reference](parameters.en.md) for all of them.

### The dependencies changed

v2.0.0 only needs `timeout` `sed` `awk` `grep` (busybox or coreutils, either is fine) — **`curl` and `flock` are no longer needed**; running outside the dpanel container additionally needs `docker`.

## 5. Rollback in practice

**This is the biggest difference from v1.x**: the rollback point is no longer the `:prev` image tag the script used to maintain. Container mode and Compose mode have **different** rollback abilities.

### Container mode: the rollback point is DPanel's backup container

Before upgrading a container, DPanel creates a backup container named `<container>-bak-<timestamp>` (for example `myapp-bak-20261103163808`). It runs the **image from before the upgrade** and is in the `Exited` state. The script never passes DPanel's `--disable-bak`, so the backup is the default behaviour — and it is your rollback point.

To roll back:

1. Find `<container>-bak-<timestamp>` in the container list of the DPanel web UI (`docker ps -a` shows it as well).
2. Use DPanel's restore / rebuild action to turn it back into the original container (same name, same config, old image).
3. The **equivalent operation at the `docker` level**: the backup container keeps the old image and the original container configuration, so you can rename it back and start it:

```sh
# Find the backup container and check that it runs the old image and is Exited
docker ps -a --filter "name=^/<container>-bak-"
docker inspect -f '{{.State.Status}} {{.Config.Image}}' <container>-bak-<timestamp>

# Make the broken container step aside
docker stop <container>
docker rm <container>

# Rename the backup container back and start it
docker rename <container>-bak-<timestamp> <container>
docker start <container>
```

> A backup container takes disk space. **Delete it only after you are sure the new version is fine** (`docker rm <container>-bak-<timestamp>`).
> A rollback only restores the **container and the image**; it does not undo the data migrations the new version has already applied. Keep separate backups of production data.

### Compose mode: no backup container, no `:prev`

DPanel's compose deploy has **no backup mechanism**: Compose mode **does not create a backup container**, and the script **does not maintain `:prev`**. A rollback can only rely on **the old image still being available locally**:

```sh
# 1. Find the ID of the old image from before the deploy
docker images --digests <repo>
# 2. Point :latest back at it and force a rebuild
docker tag <old image ID> <repo>:latest
docker compose up -d --force-recreate
```

This is an **emergency measure**, not a regular way back:

- If the old image is gone locally (cleaned up), there is no way back — **check that the old image is still there before you deploy**.
- If a `<repo>:prev` tag from the v1.x era is still on the machine, you can use it as the old image (`docker tag <repo>:prev <repo>:latest` and rebuild), but v2.0.0 will not move or maintain that tag.
- The long-term answer is to **rehearse in a test project first**: confirm the new version is fine, and only then let the same flow touch production.

## 6. Investigating leftovers from before the upgrade

v2.0.0 **no longer creates** mutex lock files, and it no longer creates `/tmp/.container-autoupdate/compose-*` / `plain-*` transaction directories. But **leftovers from before the upgrade are still there**: v1.x lock files, pull processes that never exited cleanly, and transaction directories.

The repository ships a **read-only** investigation script `scripts/ct-stale-lock-check.sh`: it changes nothing and kills nothing; it only lists the following and ends with copy-pasteable cleanup commands:

1. the old mutex lock files;
2. who is holding those lock files open (PID / PPID / fd / command line);
3. leftover image pull processes (`images/create`);
4. the leftover directories under `/tmp/.container-autoupdate` (marking which ones may be deleted and which ones must be kept).

### How to use it

```sh
curl -fsSL -L https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh \
  -o /tmp/ct-stale-lock-check.sh
sh /tmp/ct-stale-lock-check.sh
```

**Run it in the environment that runs the updates**: it inspects that machine's `/proc`. With DPanel that means inside the container:

```sh
docker cp /tmp/ct-stale-lock-check.sh dpanel:/tmp/ct-stale-lock-check.sh
docker exec -it dpanel sh /tmp/ct-stale-lock-check.sh
```

Optional environment variables: `CT_LOCK_PREFIX` (lock file prefix, `/tmp/.container-autoupdate` by default) and `CT_STATE_ROOT` (the directory to list, `/tmp/.container-autoupdate` by default).

### Clean up after reading the result

Once you have confirmed that nothing in the list is still needed, run the cleanup by hand:

```sh
# 1) Old lock files (v2.0.0 no longer uses a lock, they are just garbage)
rm -f /tmp/.container-autoupdate/*.lock

# 2) A leftover pull process: look at its command line first and only kill it when you are sure
cat /proc/<PID>/cmdline | tr '\0' ' '
kill <PID>

# 3) Transaction directories left by v1.x (read the logs inside first, confirm the problem is solved)
rm -rf /tmp/.container-autoupdate/compose-<project>
```

Keep the `compat/` directory: it holds the cross-version records (`COMPAT_ROOT`), and deleting it only means one extra notice on the next upgrade.

## 7. Common questions

**Q: Compose reports `commonDataNotFoundOrDeleted`. What now?**
A: The project is **not registered in DPanel**. The script recognises it and prints the migration path (exit code `1`; nothing was done to the project):

```text
[2026-11-03 06:00:12] ERR DPanel 里没有登记名为 myapp 的 Compose 项目
[2026-11-03 06:00:12]     compose:deploy 只能操作 DPanel「Compose」页面里登记过的项目
[2026-11-03 06:00:12]     处理方式二选一：
[2026-11-03 06:00:12]       1) 在 DPanel 网页里新建 Compose 项目，名称填 myapp（指向它的 docker-compose.yaml）
[2026-11-03 06:00:12]       2) 改用容器模式：--container <该项目里的容器名>
[2026-11-03 06:00:12]     项目未做任何改动

→ ERR: there is no Compose project named myapp registered in DPanel
→     compose:deploy can only operate on projects registered on DPanel's "Compose" page
→     two ways to fix it:
→       1) create a Compose project in the DPanel web UI named myapp (pointing at its docker-compose.yaml)
→       2) switch to container mode: --container <the container name inside that project>
→     the project was not modified
```

Pick one of the two ways: create or import the Compose project in the DPanel web UI (the name must match `--compose`), or switch to `--container`.

**Q: The task failed with `这个参数已经不能用了：xxx` and exit code `3`.**
A: Your start command still uses a v1.x form. Change it following the "migration path" in the log; the removal lists are in [section 4](#4-migrating-from-v1x). Do not just add `--compat` at random — the wrong version stops hard on every run (see [section 3](#3-compatibility-mechanisms)).

**Q: The script runs on the host — how do I point it at the DPanel container?**
A: Add `--dpanel-container <name>` (`dpanel` by default). The script then calls DPanel through `docker exec <name> /app/server/dpanel ...` and needs a working `docker` command on the machine (it probes with `docker version` first). Use `--dpanel-bin <path>` when the DPanel CLI is not at the default path, and `--dpanel-docker-env <name>` when the docker environment inside DPanel is not `local`.

**Q: The scheduled task is killed halfway through and exits with `143`.**
A: DPanel's "execution timeout" was reached. Look at three things together: the DPanel execution timeout (set it to ≥ 600 seconds), the script's hard limit for the whole round `T_HARD` (540 seconds by default), and the timeout of one upgrade / deploy `DP_T_UPGRADE` (420 seconds by default, and actually narrowed to the remaining budget). **The internal timeout must be clearly smaller than the external one**, otherwise a SIGKILLed round may leave only `signal: killed` in the log.

**Q: `--dry-run` did nothing at all in Compose mode.**
A: That is honest reporting: DPanel's `compose:deploy` is the deploy action itself and knows no "check only". In Compose mode `--dry-run` prints one line of explanation and exits (exit code `0`) without touching anything. To rehearse, run it for real in a **test project**, or check a single container with `--container`.

**Q: The log says `OK DPanel 已部署 Compose 项目 X` — does that mean it is on the latest version?**
A: Not necessarily. `OK` only means DPanel finished this deploy (the script explicitly passes `--pull-image dpanel` so that DPanel pulls the images before deploying), but a deploy does not guarantee the version changed. Take the actual version from DPanel's operation records, or from the image the container really runs.

**Q: Can one run update several targets at once?**
A: No, one process handles one target. Different targets can each have their own scheduled task; put only one on each target.

**Q: Can the script race several image mirror addresses in parallel and take the fastest?**
A: Not needed. Every image pull is done by DPanel / the Docker daemon using the registry mirrors you and the daemon configured; the script never touches a registry. That idea was evaluated historically and never implemented.
