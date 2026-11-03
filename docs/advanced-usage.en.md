# Advanced usage

> Language: [English](advanced-usage.en.md) | [中文](advanced-usage.md)

> For the basic usage see the [README](../README.en.md); all arguments are in the [parameter reference](parameters.en.md).
>
> As of v2.1.0 the script **no longer pulls images or recreates containers itself**: it only decides whether an update is needed, then hands the action over according to the mode
> (containers to DPanel's `container:upgrade`; Compose projects to `docker compose pull` + `docker compose up -d`, an in-place redeploy),
> and reports the result faithfully. See [How it works and safety boundaries](how-it-works.en.md) for the mechanics.
>
> So this page covers: how to configure the DPanel scheduled task, exit codes, breaking changes and migration, how to roll back, and how to clean up leftovers from before the upgrade.

## 1. DPanel scheduled task

### One block in the script box

Create a scheduled task and put the whole block below in the script box (there is no bootstrapper as of v3.0.0: download, verify and run all happen here):

```sh
U1='https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh'
U2='https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh'
T=/tmp/ct-new.sh
curl -fsSL --max-time 60 "$U1" -o "$T" || curl -fsSL --max-time 60 "$U2" -o "$T" || true
if [ "$(wc -c <"$T" 2>/dev/null || echo 0)" -gt 1000 ] && sh -n "$T" 2>/dev/null \
   && grep -q container-autoupdate "$T"; then
  mv -f "$T" /tmp/container-autoupdate.sh
fi
[ -s /tmp/container-autoupdate.sh ] || { echo "ERR 拿不到可用的更新脚本"; exit 1; }
sh /tmp/container-autoupdate.sh --compose myapp
```

- Do not write `curl ... | sh`: with a pipe a failed download **silently succeeds** (the task log cannot show that this round did nothing). The block above lands the download in a temporary file, overwrites only after three checks pass, returns non-zero explicitly on failure, and **falls back to the previous copy** when the download fails.
- To pin a version in production, replace `latest/download` in both URLs with `download/v3.0.0` (version numbers are on the [Releases](https://github.com/geekMus/container-autoupdate/releases) page).
- The two modes:

| How your container was started | Which argument | What the script actually runs |
|---|---|---|
| `docker compose up -d` | `--compose <project>` | `docker compose pull` + `docker compose up -d` (an in-place redeploy) |
| `docker run ...` | `--container <name>` | `dpanel container:upgrade --name <name>` (first without `--upgrade` to check, and only then with it) |

Compose mode **does not need prior registration**: the script looks the project directory and compose file up directly from the container labels, and only falls back to `--compose-dir` when that lookup fails (see section 7).
Container mode still depends entirely on DPanel — without DPanel there is no way to update a container.

### Set the execution timeout to ≥ 600 seconds

- The script's own hard limit for a round is `T_HARD` (540 seconds by default). DPanel's "execution timeout" must be **clearly larger**, so use **≥ 600 seconds** (`scriptRunTimeout=600`).
- The timeout of a single call is controlled separately: in container mode `DP_T_CHECK` (the check, 120 seconds by default) and `DP_T_UPGRADE` (the upgrade, 420 seconds by default);
  in Compose mode `DP_T_CHECK` (listing the images), `DP_T_PULL` (the pull, 420 seconds by default) and `DP_T_UP` (the redeploy, 180 seconds by default).
  Every call is additionally narrowed to the remaining budget.
- If the timeout is too short, the round is killed by DPanel and ends with exit code `143`; a round that was SIGKILLed may leave only `signal: killed` in the log, with no reason visible at all.
- When DPanel edits a task in the UI it rewrites the task's settings JSON, and the "execution timeout" you typed by hand can be dropped (measured). After changing the schedule, come back and check it once.
- When less than `DP_MIN_UPGRADE` (90 seconds by default) of the budget is left, the script **does not act**: it reports the failure honestly and exits with `1`, and the next round retries.

### One scheduled task per target

The script takes **no mutex lock** internally; concurrency is guaranteed by the DPanel scheduled task. Two rounds for the same target at the same time step on each other, so **one scheduled task per target**.

Different targets do not affect each other and can each have their own task (see section 7).

### Seeing the reason when it fails

A DPanel scheduled task **keeps only stderr when the task fails** (and only stdout when it succeeds). That is why the script writes the failure reason (the `ERR` / `CRITICAL` lines and the indented continuation lines right after them) to **both** stdout and the real stderr — a design from v1.1.2, kept ever since. A failed task then shows the reason directly instead of a bare `exit status 1`.

> Side effect: when you merge stdout and stderr into one file by hand, the error lines appear twice.

### Running one round manually

That is allowed, but it is only a **one-off run**:

```sh
docker exec -it dpanel sh -c 'curl -fsSL --max-time 60 https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh -o /tmp/container-autoupdate.sh && sh /tmp/container-autoupdate.sh --compose myapp'
```

### cron / systemd timer are not recommended

The script contains no scheduling and takes no mutex lock. If you run it on a schedule with cron or a systemd timer, **you have to guarantee yourself that two rounds for the same target never run at the same time**. For scheduled updates, use a DPanel scheduled task.
(If you really insist on cron, stagger the times in the crontab expression.)

### The script never touches the registry

In Compose mode the pull is done by `docker compose pull`, using **the registry mirrors you and the daemon configured**. The script never touches a registry, so "racing several image mirror addresses in parallel" is no longer needed — and was never implemented (it was evaluated historically).

## 2. Exit codes

| Exit code | Meaning | What to do |
|---|---|---|
| `0` | Successful update / already up to date / `--dry-run` check only | Nothing to do |
| `1` | Failure: in container mode DPanel reported an error; in Compose mode the pull failed, the redeploy failed, a container is not running after the deploy, or the project directory cannot be found; also not enough time was left, a dependency is missing, or an argument is wrong (**the target is left as it was**) | Look at the `ERR` in the log; the script never leaves the target half-updated |
| `2` | **Reserved**: not produced at present (container rollback is DPanel's job and the script cannot see it; in Compose mode a failed deploy means the script deployed nothing) | — |
| `3` | **A breaking change was detected** and your invocation no longer works (nothing was changed this round) | Change the command following the "migration path" in the log; or pin a version; or add `--compat` |
| `130` | Interrupted by Ctrl-C (`SIGINT`) | You pressed Ctrl-C on a manual run; harmless |
| `143` | Interrupted by `SIGTERM` / `SIGHUP` (the usual case is a scheduled task timing out) | The "execution timeout" is too short; raise it, or lower `T_HARD` |

### What the three Compose-mode failures look like

Compose mode has exactly one action — deploy — and its failures come in three shapes. **None of them leaves the project half-updated**:

- **The pull failed**: the script **does not deploy**, the project is untouched, exit code `1`:

```text
[2026-11-03 06:00:12] ERR 拉取失败（docker compose pull 退出码 1），本轮不部署，项目保持原样
[2026-11-03 06:00:12]     <compose 自己的最后 5 行输出>
```

- **The redeploy failed**: exit code `1`, with compose's own words printed out:

```text
[2026-11-03 06:00:12] ERR 重新部署失败（docker compose up -d 退出码 1）
[2026-11-03 06:00:12]     <compose 自己的最后 5 行输出>
[2026-11-03 06:00:12]     compose 文件与容器定义都没被脚本改过，可以直接再跑一轮
```

- **The deploy succeeded but a container is not running**: exit code `1`, naming each container and pointing at `docker compose logs <service>`:

```text
[2026-11-03 06:00:12] ERR 有容器没在运行（1/3 running）：
[2026-11-03 06:00:12]     myapp-worker exited
[2026-11-03 06:00:12]     compose 文件没被改过；用 docker compose logs <服务名> 看具体原因
```

→ ERR: the pull failed (docker compose pull exit code 1); nothing was deployed this round, the project is untouched
→ ERR: the redeploy failed (docker compose up -d exit code 1)
→     neither the compose file nor the container definitions were changed by the script; you can simply run another round
→ ERR: some containers are not running (1/3 running):
→     myapp-worker exited
→     the compose file was not changed; use docker compose logs <service> to see the reason

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
```

→ ERR: this environment variable can no longer be used: LOCK_PREFIX (current value=/tmp/.container-autoupdate)
→     as of v1.0.0: LOCK_PREFIX has been removed
→     reason: since 1.0.0 the script no longer uses a mutex lock; concurrency is guaranteed by the DPanel scheduled task
→     migration path: just delete LOCK_PREFIX, no replacement setting is needed
→     or pin the download URL to an old version (see "Versions and upgrades" in the README)
→     nothing was changed this round; exit code 3

The removed arguments and environment variables are listed in section 4.

### Cross-version notice

The script remembers **the version each target last ran with** (kept under `COMPAT_ROOT`, one `lastver` per target; `/tmp/.container-autoupdate/compat/compose-<project>/lastver` by default, or `container-<name>` in container mode). When it upgrades to a version with a breaking change, the log gets a `WARN` block explaining what changed and what to do, and then **carries on**:

```text
[2026-11-01 03:52:03] WARN 你从 1.0.0 之前的版本(0.9.0)升级上来，v1.0.0 引入了破坏性变更
[2026-11-01 03:52:03]      变更：1.0.0 起移除脚本内的互斥锁：v0.4.0 的锁会被残留的子进程长期占住，导致之后每一轮都跳过
[2026-11-01 03:52:03]      应对：同一目标只挂一个 DPanel 计划任务
[2026-11-01 03:52:03]      本次仍会继续执行。两条路选一条：
[2026-11-01 03:52:03]        1) 接受上面的新做法（想让下一次破坏性变更前先停住，可加 --compat 1.0.0）
[2026-11-01 03:52:03]        2) 想继续用旧行为，把下载地址固定到 v0.9.0 那个 tag
```

→ WARN: you upgraded from a version before 1.0.0 (0.9.0); v1.0.0 introduced a breaking change
→       change: since 1.0.0 the mutex lock inside the script is gone ...
→       how to deal with it: put only one DPanel scheduled task on each target
→       this round still continues. Pick one of the two paths:
→        1) accept the new behaviour above (to stop before the next breaking change, add --compat 1.0.0)
→        2) keep the old behaviour and pin the download URL to the v0.9.0 tag

It does **not abort** (it cannot know whether you depend on the old behaviour), it only notifies. The same version is not announced twice, and a downgrade is not announced at all.

> Note: **do not put the old version number from the notice into `--compat`** (in the example that is `0.9.0`) — `--compat` means "I have verified up to vX", so a version older than the change declares "I have not verified this change" on every single run and therefore **stops hard every time** (exit code `3`).
> To "stop before the change" you should write **the current script version** (`sh container-autoupdate.sh --version` prints it; the log's first line `container-autoupdate v<version> 启动` carries it as well).

### `--compat <version>`

It declares "I have only verified up to this version". If the script is newer and a registered `behavior` change lies in between, it **stops hard** with exit code `3`:

```sh
container-autoupdate.sh --compose myapp --compat 1.2.3
```

(`1.2.3` is an example placeholder — replace it with the version you **verified**.)

The two ways to use `--compat` are opposites, so do not mix them up:

| What you write | How the script reacts |
|---|---|
| **The current script version** (see `--version`) | **This round still runs**; but the moment a breaking change newer than it appears, the script stops hard (exit code `3`) — this is the correct way to "stop before the change" |
| A version **older than the change** | It stops hard on every run (exit code `3`): you are declaring "I have not verified this change", and the change is right there in the script |

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

These three arguments are **gone**: passing one makes the script abort at once with exit code `3` and print the migration path.

| Removed argument | What it used to do | What to do now |
|---|---|---|
| `--state-dir` | Set the state directory | Not needed: the cross-version record moved to `COMPAT_ROOT` (`/tmp/.container-autoupdate/compat` by default) |
| `--bad-ttl-days` | Bad-version pinning period | Not needed: there is no bad-version pinning any more; rollback is DPanel's job |
| `--pull-retries` | Pull retry count | Not needed: in container mode DPanel performs the pull, in Compose mode `docker compose pull` does |

`--compose-dir` is **not** on the removal list: it is **available again** as of v2.1.0, with the same meaning as before — it tells the script the directory of the Compose project.
It is now an **optional fallback**: while the project still has containers, the script reads the directory and the compose file from the `com.docker.compose.project.*` labels; you only need it when the project has no container at all (for example it has never been deployed). The equivalent environment variable `COMPOSE_DIR` is available again too.

### Removed environment variables

These environment variables are gone (still setting one aborts with exit code `3`); the migration path is always to **delete it**, with no replacement:

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
| `COMPOSE_BASE` | Fallback root for the Compose directory |

> Two exceptions: `T_INSPECT` **is still accepted** and is equivalent to `DP_T_CHECK`, so old tasks keep working without a config change;
> and `COMPOSE_DIR` **is available again**, equivalent to `--compose-dir` (see the previous subsection).

### Delete the obsolete variables from your DPanel scheduled task

A scheduled task carried over from v1.x usually still holds some of the items above in its script box or environment. **Whatever is left there aborts the script on that item (exit code `3`)**, and the round does nothing.

```text
[2026-11-01 03:47:12] ERR 这个环境变量已经不能用了：T_STALL（当前值=60）
[2026-11-01 03:47:12]     从 v2.0.0 起：T_STALL 已移除
[2026-11-01 03:47:12]     原因：2.0.0 起脚本不再读 Docker 拉取流，拉取停滞判定取消
[2026-11-01 03:47:12]     迁移方式：删掉 T_STALL 即可，不需要任何替代设置
[2026-11-01 03:47:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-01 03:47:12]     本次未做任何改动，退出码 3
```

→ ERR: this environment variable can no longer be used: T_STALL (current value=60)
→     as of v2.0.0: T_STALL has been removed
→     reason: since 2.0.0 the script no longer reads the Docker pull stream, so stall detection is gone
→     migration path: just delete T_STALL, no replacement setting is needed
→     or pin the download URL to an old version (see "Versions and upgrades" in the README)
→     nothing was changed this round; exit code 3

Do this once before and once after the migration:

1. **Before**: delete every obsolete item from the task's script / environment one by one (check them against the table above).
2. **After**: run one manual round `docker exec -it dpanel sh -c 'sh /tmp/container-autoupdate.sh --compose myapp --dry-run'` to confirm the target and the project directory the script picked up are right, then drop `--dry-run`.

### `LOCK_PREFIX` still aborts

`LOCK_PREFIX` belongs to the earlier 1.0.0 breaking change (the mutex lock inside the script was removed) and is still in `BREAKING_TABLE`. A leftover `LOCK_PREFIX=...` in the start command still aborts the script with exit code `3`; just delete it.

### New arguments and environment variables

| Argument | Environment variable | Default | Notes |
|---|---|---|---|
| `--compose-dir <path>` | `COMPOSE_DIR` | empty | Compose project directory; the fallback when the label lookup fails (restored in v2.1.0) |
| `--dpanel-container <name>` | `DPANEL_NAME` | `dpanel` | Name of the container DPanel runs in; used only when debugging (running outside the dpanel container) |
| `--dpanel-bin <path>` | `DPANEL_BIN` | `/app/server/dpanel` | Path of the DPanel CLI |
| `--dpanel-docker-env <name>` | `DPANEL_DOCKER_ENV` | `local` | `--docker-env` passed to the DPanel CLI |

| Variable | Default | Notes |
|---|---|---|
| `COMPAT_ROOT` | `/tmp/.container-autoupdate/compat` | Directory of the cross-version records (one `lastver` per target) |
| `T_HARD` | `540` | Hard limit for the whole round (seconds) |
| `DP_T_CHECK` | `120` | Timeout of one "check" call (seconds); the old `T_INSPECT` is still accepted |
| `DP_T_UPGRADE` | `420` | Timeout of one container-upgrade call (seconds) |
| `DP_T_PULL` | `420` | Timeout of `docker compose pull` in Compose mode (seconds) |
| `DP_T_UP` | `180` | Timeout of `docker compose up -d` in Compose mode (seconds) |
| `DP_MIN_UPGRADE` | `90` | Below this much remaining budget the script does not act (seconds) |

Retained arguments: `--compose`, `--container`, `--docker-sock`, `--compat`, `--dry-run`, `-h` / `--help`, `-V` / `--version`. See the [parameter reference](parameters.en.md) for all of them.

### The dependencies changed

The script needs only `timeout` `sed` `awk` `grep` (busybox or coreutils, either is fine) — **`curl` and `flock` are no longer needed**.
In addition:

- **Container mode**: the DPanel CLI is required (the script probes it with `dpanel version`). Running outside the dpanel container additionally needs `docker`.
- **Compose mode**: `docker` and the **Docker Compose v2 plugin** (`docker compose`, not `docker-compose`). If the plugin is missing it reports:

```text
[2026-11-03 06:00:12] ERR 无法执行 docker compose（缺 compose 插件？）
[2026-11-03 06:00:12]     Compose 模式需要 Docker Compose v2 插件版（docker compose，不是 docker-compose）
```

→ ERR: cannot run docker compose (missing the compose plugin?)
→     Compose mode needs the Docker Compose v2 plugin (docker compose, not docker-compose)

## 5. Rollback in practice

**This is the biggest difference from v1.x**: the rollback point is no longer the `:prev` image tag the script used to maintain. Container mode and Compose mode have **different** rollback abilities — one has a backup container, the other has none.

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

# Make the broken new container step aside
docker stop <container>
docker rm <container>

# Rename the backup container back and start it
docker rename <container>-bak-<timestamp> <container>
docker start <container>
```

> A backup container takes disk space. **Delete it only after you are sure the new version is fine** (`docker rm <container>-bak-<timestamp>`).
> A rollback only restores the **container and the image**; it does not undo the data migrations the new version has already applied. Keep separate backups of production data.

### Compose mode: no backup container, no `:prev`

In Compose mode `docker compose up -d` has **no backup mechanism**: it **does not create a backup container**, and the script **does not maintain `:prev`**. A rollback can only rely on **the old image still being available locally**:

```sh
# 1. Find the ID of the old image from before the deploy
#    Easiest source: the previous round's log line "已重建：<name>（旧12位 → 新12位）" — the left-hand side is the old image's 12-char id
#    Or look it up yourself: docker images --digests <repo>
# 2. Point :latest back at it and force a rebuild
docker tag <old image ID> <repo>:latest
docker compose up -d --force-recreate
```

This is an **emergency measure**, not a regular way back:

- If the old image is gone locally (cleaned up), there is no way back — **check that the old image is still there before you deploy**.
- If a `<repo>:prev` tag from the v1.x era is still on the machine, you can use it as the old image (`docker tag <repo>:prev <repo>:latest` and rebuild), but the script will not move or maintain that tag any more.
- The long-term answer is to **rehearse in a test project first**: confirm the new version is fine, and only then let the same flow touch production.

### The rollback abilities of the two modes side by side

| Mode | Rollback point | How to roll back | Where exit code 2 appears |
|---|---|---|---|
| Container mode | DPanel's backup container `<container>-bak-<timestamp>` (runs the old image, `Exited`) | DPanel web UI restore / rename; or `docker stop` + `rm` the new container → `docker rename` the backup → `docker start` | Nowhere: rollback is DPanel's job and the script cannot see it |
| Compose mode | **None** (no backup container, no `:prev`) | `docker tag <old image ID> <repo>:latest` → `docker compose up -d --force-recreate` | Nowhere: when the pull fails the script does not deploy at all |

## 6. Investigating leftovers from before the upgrade

The script **no longer creates** mutex lock files, and it no longer creates `/tmp/.container-autoupdate/compose-*` / `plain-*` transaction directories. But **leftovers from before the upgrade are still there**: v1.x lock files, pull processes that never exited cleanly, and transaction directories.

The repository ships a **read-only** investigation script `scripts/ct-stale-lock-check.sh`: it changes nothing and kills nothing; it only lists the following and ends with copy-pasteable cleanup commands.
Its usage is unchanged — it has always inspected the v1.x-era lock files and leftover pull processes, and that has nothing to do with which update path the script takes today:

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
# 1) Old lock files (the script no longer uses a lock, they are just garbage)
rm -f /tmp/.container-autoupdate/*.lock

# 2) A leftover pull process: look at its command line first and only kill it when you are sure
cat /proc/<PID>/cmdline | tr '\0' ' '
kill <PID>

# 3) Transaction directories left by v1.x (read the logs inside first, confirm the problem is solved)
rm -rf /tmp/.container-autoupdate/compose-<project>
```

Keep the `compat/` directory: it holds the cross-version records (`COMPAT_ROOT`), and deleting it only means one extra notice on the next upgrade.

## 7. Common questions

**Q: Container mode reports `ERR DPanel 检查失败`. What now?**
A: The script has already passed DPanel's original error text through after the colon — read that sentence first. The two most common causes: the container name is wrong (DPanel will say it cannot find the container), or the DPanel CLI cannot be reached at all. A CLI that cannot be reached looks different — it is `ERR 无法调用 DPanel CLI`:

```text
[2026-11-03 06:00:12] ERR 无法调用 DPanel CLI（/app/server/dpanel）
[2026-11-03 06:00:12]     脚本当前环境里没有这个可执行文件

[2026-11-03 06:00:12] ERR 无法调用 DPanel CLI（/app/server/dpanel）
[2026-11-03 06:00:12]     已尝试：docker exec dpanel /app/server/dpanel version
[2026-11-03 06:00:12]     DPanel 容器名不是 dpanel 时用 --dpanel-container 指定，路径不同用 --dpanel-bin
```

→ ERR: cannot call the DPanel CLI (/app/server/dpanel)
→     this environment does not have that executable
→ ERR: cannot call the DPanel CLI (/app/server/dpanel)
→     tried: docker exec dpanel /app/server/dpanel version
→     when the DPanel container is not named dpanel use --dpanel-container; a different path needs --dpanel-bin

The two shapes have two fixes: when running inside the dpanel container, `/app/server/dpanel` must be an executable file (use `--dpanel-bin` for a different path); when running elsewhere, use `--dpanel-container` for the container name and `--dpanel-bin` for the in-container path.

**Q: Compose reports `找不到 Compose 项目 X 的项目目录`. What now?**
A: The script first looks the project directory up from the container labels and only reports this when that lookup fails (the project has **no container at all**, for example it has never been deployed). Point it at the directory with `--compose-dir`:

```text
[2026-11-03 06:00:12] ERR 找不到 Compose 项目 myapp 的项目目录
[2026-11-03 06:00:12]     当前 Docker 里没有带「myapp」这个 compose 项目标签的容器，反查不到
[2026-11-03 06:00:12]     处理方式二选一：
[2026-11-03 06:00:12]       1) 用 --compose-dir <路径> 指定 compose 文件所在目录
[2026-11-03 06:00:12]       2) 确认项目名写法；项目还没部署过就先手动 compose up 一次
```

→ ERR: cannot find the project directory of Compose project myapp
→     no container in Docker carries the "myapp" compose project label, so it cannot be looked up
→     two ways to fix it:
→       1) use --compose-dir <path> to point at the directory holding the compose file
→       2) check the project name; and if the project has never been deployed, run compose up once by hand

Pick one of three ways: write `--compose-dir /opt/myapp` (or set `COMPOSE_DIR`); check the spelling of the `--compose` project name; or the project really has never been started, so run `docker compose up -d` by hand once and the container labels will make the lookup work afterwards.
A neighbouring error is a directory that exists on paper only: `ERR Compose 项目目录不存在：<路径>` — the directory was deleted or the path is wrong, again with exit code `1`.

**Q: Compose reports some containers are not running. What now?**
A: `docker compose up -d` itself succeeded, but the script found containers in this project that are not running (`exited` / `restarting` / `dead` are all named), so it reports the failure honestly with exit code `1`. Follow the hint and read that service's log:

```sh
docker compose logs <service>        # run it in the project directory
```

**Q: What is the difference between `OK Compose 项目 X 已是最新` and "redeployed / deployed (new)"?**
A: They are three different facts, and the script reports them separately:

| Log line | The fact |
|---|---|
| `OK Compose 项目 X 已是最新（拉取后没有容器需要重建）` | `docker compose pull` succeeded, but after the pull **no container needs rebuilding** — the images did not change and `up -d` was a no-op. This is the conclusion of "the pull itself is the check", not a prediction |
| `OK Compose 项目 X 已重新部署（N/M 个容器换了镜像）` | Containers changed image: each one printed `已重建：<名>（旧12位 → 新12位）` |
| `OK Compose 项目 X 已部署（K 个容器新建）` | Those containers did not exist before the deploy (a first deploy, or services newly added to the compose file): each one printed `新建：<名>（新12位）` |

Compose mode **has no "check whether a new version exists" ability**: the only way to know is `docker compose pull` itself. `--dry-run` does not check either — it lists the images the project involves and exits with `0`:

```text
[2026-11-03 06:00:12] DRY 只检查不动手：上面是这个项目涉及的镜像，本轮不拉取、不部署
[2026-11-03 06:00:12]     要真正更新就去掉 --dry-run（拉取本身就是「有没有新版本」的判断）
```

→ DRY: check only, no action: those are the images involved in this project; nothing is pulled or deployed this round
→     to actually update, drop --dry-run (the pull itself is what decides whether there is a new version)

(Container mode's `--dry-run` means something different: it really does ask DPanel and reports "a new version was found" without upgrading.)

**Q: The log says `WARN 剩余时间不足（…），本轮不部署，项目保持原样` — is something broken?**
A: No. The budget left for this round is below `DP_MIN_UPGRADE` (90 seconds by default) and the script **deliberately does not act**, so that it is not SIGKILLed by the scheduled task halfway through (such a round leaves nothing in the log). Exit code `1`. The next scheduled round decides again. If it happens for a long time, raise `T_HARD` or the task's execution timeout.

**Q: The task failed with `这个参数已经不能用了：xxx` or `这个环境变量已经不能用了：xxx` and exit code `3`.**
A: Your start command / scheduled task still uses an old form. Change it following the "migration path" in the log; the removal lists are in [section 4](#4-migrating-from-v1x). Do not just add `--compat` at random — the wrong version stops hard on every run (see [section 3](#3-compatibility-mechanisms)).

**Q: Which version should `--compat` carry?**
A: The version you have **verified**. To "stop before the change and not let it upgrade itself", write **the current script version** (`sh container-autoupdate.sh --version`): this round still runs, but a newer breaking change stops it hard (exit code `3`). Writing a version **older than the change** is the opposite — the script stops hard every time, because it judges "you have not verified this change".

**Q: The script runs on the host — how do I point it at the DPanel container?**
A: Add `--dpanel-container <name>` (`dpanel` by default). The script then calls DPanel through `docker exec <name> /app/server/dpanel ...` and needs a working `docker` command on the machine (it probes with `docker version` first). Use `--dpanel-bin <path>` when the DPanel CLI is not at the default path, and `--dpanel-docker-env <name>` when the docker environment inside DPanel is not `local`.

**Q: The scheduled task is killed halfway through and exits with `143`.**
A: DPanel's "execution timeout" was reached. Look at three things together: the DPanel execution timeout (set it to ≥ 600 seconds), the script's hard limit for the whole round `T_HARD` (540 seconds by default), and the single-call timeouts (`DP_T_UPGRADE` 420 seconds, `DP_T_PULL` 420 seconds and `DP_T_UP` 180 seconds by default, each actually narrowed to the remaining budget). **The internal timeout must be clearly smaller than the external one**, otherwise a SIGKILLed round may leave only `signal: killed` in the log.

**Q: Can one run update several targets at once?**
A: No, one process handles one target. Different targets can each have their own scheduled task; put only one on each target.

**Q: Can the script race several image mirror addresses in parallel and take the fastest?**
A: Not needed. In Compose mode the pull is done by `docker compose pull` using the registry mirrors you and the daemon configured; in container mode the pull is DPanel's job. The script never touches a registry. That idea was evaluated historically and never implemented.
