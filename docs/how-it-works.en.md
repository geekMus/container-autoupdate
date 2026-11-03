# How it works and safety boundaries

> Language: [English](how-it-works.en.md) | [中文](how-it-works.md)

> This page explains **how** the script works, **when it refuses to act**, and **what it cannot protect**. It is worth three minutes of reading before you use it.

## 1. What it does in one sentence

Since v2.0.0 the script **no longer pulls images and no longer rebuilds containers itself**: it does exactly three things —

1. **Decide whether an update is due** (ask DPanel "does this target have a new version");
2. **Hand the update action over to DPanel**;
3. **Report DPanel's result truthfully** (success / failure / nothing to update).

Every update capability comes from DPanel's own command line: containers go through `container:upgrade`, Compose projects through `compose:deploy`.

Why it was changed:

- Rebuilding a container yourself means **faithfully reproducing** networks, mounts (including real names of anonymous volumes), resource limits, restart policies, capabilities… and missing one of them is a production incident. v1.x spent more than a thousand lines on that and still hit problems such as "a stalled pull judged wrongly" and "the failure reason printed twice".
- DPanel already has mature implementations of both jobs, and its backup container is a ready-made rollback point.
- The script therefore shrank from 1700+ lines to roughly 700 lines: a smaller surface, easier to keep under control.

## 2. Prerequisites

- **It must run on a machine with DPanel installed**: the update actions rely on DPanel's CLI.
- **Running it inside the DPanel container is recommended** (a DPanel scheduled task runs inside the `dpanel` container by default): the script calls `/app/server/dpanel` directly.
- If it runs on the host (not inside the dpanel container): the host needs the `docker` command, and the script calls it via `docker exec dpanel /app/server/dpanel ...`. Use `--dpanel-container` to name the container (default `dpanel`).
- **Compose mode requires the project to be already registered in DPanel** (DPanel web UI → Compose → create/import). When it is not registered DPanel returns `{"code":500,"error":"...commonDataNotFoundOrDeleted..."}`; the script recognises that and prints a migration path, exit code `1`.
- Required commands: `timeout` `sed` `awk` `grep` (busybox or coreutils both work). **`curl` and `flock` are no longer needed**. Outside the dpanel container, `docker` is needed as well.

For the parameters and environment variables see [the parameter docs](parameters.en.md#all-command-line-parameters).

## 3. What one round does

```
1. Parse the arguments
2. Compatibility check: an old flag / old environment variable that matches is aborted with a migration path (exit code 3)
   --compat <version> declares "I only verified up to some version" → a newer breaking change stops it hard
3. Dependency self-check: timeout / sed / awk / grep; plus docker when not inside the dpanel container
   then call the DPanel CLI (dp_cli version) to confirm it really is available
4. Hand the update over according to the mode:
     container      → container:upgrade (first without --upgrade, check only)
     Compose project → compose:deploy --name <project> --pull-image dpanel
5. Report the result (OK / ERR / WARN / DRY)
6. Write lastver (the "this target has seen the current version" record used for cross-version notices)
7. Exit
```

Two orderings are deliberate:

- **The compatibility check comes before the dependency self-check** — when your invocation is no longer valid you should see the migration instructions first, rather than being sent off by a "cannot find docker / cannot find the DPanel CLI" message that points in an unrelated direction.
- **The cross-version `WARN` is printed before the dependency self-check, but `lastver` is written only after it** — a round that fails the dependency self-check does not count as "the user has been told", so the notice appears again next time.

## 4. The full flow of container mode (`--container`)

1. `container:upgrade --name <container> --docker-env local` (**without** `--upgrade`) = **check only**. DPanel compares the remote and local digests itself and returns JSON:

   ```json
   {"upgrade":true,"digest":"sha256:a5c10db1...","digestLocal":["ghcr.1ms.run/yetone/magpie@sha256:d9d64cc1..."],"error":"","message":"","status":"upgrade"}
   ```

2. `upgrade` is **not** `true` → it is "already up to date". The script prints `OK 容器 <名> 已是最新（DPanel 报告 status=latest）`, exit code `0`, and **the container was not touched at all**.

   ```text
   [2026-11-03 16:38:08] OK 容器 myapp 已是最新（DPanel 报告 status=latest）
       → OK: container myapp is already up to date (DPanel reports status=latest)
   ```

3. `--dry-run` → it prints `发现新版本（远端 digest=sha256:...）` + `DRY 只检查不动手，本轮不升级`, exit code `0`.

   ```text
   [2026-11-03 16:38:08] 发现新版本（远端 digest=sha256:a5c10db1...）
   [2026-11-03 16:38:08] DRY 只检查不动手，本轮不升级
       → DRY: check only, no action taken; this round does not upgrade
   ```

4. Not enough time left (`< DP_MIN_UPGRADE`, 90 seconds by default) → **no action**, exit code `1`:

   ```text
   [2026-11-03 16:38:08] WARN 剩余时间不足（40s < 90s），本轮不启动升级，容器保持原样
   [2026-11-03 16:38:08]      下一轮计划任务会重新检查；也可以把 T_HARD 或计划任务的超时调大
       → WARN: not enough time left (40s < 90s); the upgrade is not started this round and the container is left as is
       →      the next scheduled task will check again; you can also raise T_HARD or the timeout of the scheduled task
   ```

5. A real upgrade adds `--upgrade`: `container:upgrade --name <container> --upgrade --docker-env local`. On success it returns `{"containerId":"..."}` and the script prints `OK DPanel 已完成升级（containerId=...）`, exit code `0`.

6. **The rollback point is the backup container DPanel creates**, named like `<container name>-bak-<timestamp>` (for example `myapp-bak-20261103163808`): it runs the image from before the upgrade and is in the Exited state. To roll back, turn it back into the real one (the backup container is visible directly in the DPanel web UI).

7. **On a failed upgrade DPanel rolls back itself** (measured: when the image is broken the container keeps the old image and a backup container is left behind). The script reports an error with exit code `1`, and the log carries DPanel's error text.

> This is **the biggest difference** between v2.0.0 and v1.x: the rollback point is no longer the `:prev` image tag but DPanel's backup container.

## 5. The full flow of Compose mode (`--compose`)

1. **It can only deploy; there is no "check only"**: DPanel's `compose:deploy` is the deployment action.
2. **`--dry-run` does nothing at all in Compose mode**, it only says so, exit code `0`:

   ```text
   [2026-11-03 16:38:08] DRY Compose 模式没有「只检查」能力（DPanel 的 compose:deploy 会直接部署）
   [2026-11-03 16:38:08]     本轮未执行部署；要检查容器有没有新版本请用 --container 模式
       → DRY: Compose mode has no "check only" capability (DPanel's compose:deploy deploys directly)
       →     nothing was deployed this round; to check whether a container has a new version, use --container mode
   ```

   A rehearsal is only possible through container mode, or by running it on a test project first.
3. A real deployment: `compose:deploy --name <project> --pull-image dpanel --docker-env local`.
4. Not enough time left (`< DP_MIN_UPGRADE`) → no deployment, exit code `1`: `WARN 剩余时间不足（40s < 90s），本轮不部署，项目保持原样`.
5. On success → it prints `OK DPanel 已部署 Compose 项目 <项目名>`, exit code `0`.

### Why `--pull-image dpanel` must be given explicitly

`--pull-image` takes `dpanel` or `command`, and **the default is `command`**. The `command` path was measured to **not pull a new image at all** (a tag that is already up to date is never fetched again), which results in "the deployment succeeded but the version did not change". So the script passes `--pull-image dpanel` explicitly, letting DPanel pull every service's image with its own pull logic before deploying.

### Both success and failure hide inside the JSON

- On success DPanel returns `{"name":"<project>"}` — **note: there is no `code` field on success**.
- A failure can be `{"code":500,...,"error":"..."}` while the **CLI exit code is still `0`** — the exit code cannot be trusted, so **success and failure must be decided by parsing the JSON**.
- The script counts it as a failure when "`code` ≥ 400, or `status=failed`, or the `error` field is non-empty", and **not** when "`code` is not 200". Writing the latter would misjudge a successful call that has no `code` as a failure.
- The project is not registered in DPanel → `commonDataNotFoundOrDeleted` → the script prints a migration path and exits `1`:

  ```text
  [2026-11-03 16:38:08] ERR DPanel 里没有登记名为 myapp 的 Compose 项目
  [2026-11-03 16:38:08]     compose:deploy 只能操作 DPanel「Compose」页面里登记过的项目
  [2026-11-03 16:38:08]     处理方式二选一：
  [2026-11-03 16:38:08]       1) 在 DPanel 网页里新建 Compose 项目，名称填 myapp（指向它的 docker-compose.yaml）
  [2026-11-03 16:38:08]       2) 改用容器模式：--container <该项目里的容器名>
  [2026-11-03 16:38:08]     项目未做任何改动
      → ERR: DPanel has no Compose project registered under the name myapp
      →      compose:deploy can only act on projects registered on DPanel's "Compose" page
      →      two ways out:
      →        1) create a Compose project in the DPanel web UI named myapp (pointing at its docker-compose.yaml)
      →        2) switch to container mode: --container <a container name of that project>
      →      the project was left untouched
  ```

## 6. When it skips / does nothing

None of these are failures: it is the script (or DPanel) deliberately not acting. The log states the exact reason.

| Situation | Result |
|---|---|
| Container mode: DPanel reports `status=latest` (`upgrade` is not `true`) | It prints `OK 容器 <名> 已是最新…`, exit code `0`, the container is not touched at all |
| `--dry-run` (container mode) | Check only and print the new version it found, exit code `0`, no upgrade |
| `--dry-run` (Compose mode) | **Does nothing at all**, exit code `0` (`compose:deploy` has no "check only" capability) |
| Not enough time left (`< DP_MIN_UPGRADE`, 90 seconds by default) | No action, exit code `1`, the target is left as it was |
| The Compose project is not registered in DPanel | It prints `ERR DPanel 里没有登记名为 <名> 的 Compose 项目` plus a migration path, exit code `1` |
| An old parameter / old environment variable matches `BREAKING_TABLE` | Aborted immediately, exit code `3`, nothing changed, the log carries the new form |
| A required command is missing (`timeout` `sed` `awk` `grep`, or `docker` when not inside the dpanel container) | It prints `ERR 缺少依赖命令：…`, exit code `1` |

Removed parameters: `--compose-dir`, `--state-dir`, `--bad-ttl-days`, `--pull-retries`; for the removed environment variables see [the parameter docs](parameters.en.md#all-environment-variables).

## 7. What it cannot protect (important)

### Compose mode has no "check only"

`compose:deploy` is the deployment action, and DPanel offers no "check without deploying" interface for Compose. So in Compose mode `--dry-run` does nothing, and there is no way to rehearse in advance; a rehearsal is only possible through container mode or on a test project.

### Compose mode creates no backup container and maintains no `:prev`

DPanel's compose deployment has no backup mechanism, and the script no longer tags `:prev` itself. So:

- **A rollback can only rely on the old image still being on the local disk**;
- **Compose mode cannot know in advance whether there is a new version**: the script does no image digest comparison (that was v1.x's job); it simply hands the deployment to DPanel and lets DPanel decide whether to rebuild. The log therefore contains no "already up to date" judgement (unless DPanel itself says so in its output).

A manual rollback in Compose mode:

```sh
# while the old image is still on the local disk (find its ID with docker images first)
docker tag <old image ID> <image repository>:latest
docker compose up -d --force-recreate
```

Container mode is the opposite: DPanel leaves a `<container name>-bak-<timestamp>` backup container. DPanel's `--disable-bak` is **not** passed by us, so backing up is the default.

### Container health and business correctness are no longer judged by the script

v1.x watched the container itself: whether the healthcheck passed and whether it was still running after start-up. Since v2.0.0 that job belongs to DPanel; the script only reports what DPanel says.

### Data is not rolled back

A rollback only restores the **container and the image**. Migrations, writes and schema changes that the new version has already applied to a data volume or a database are **not** undone by the rollback.

> For containers running a database or any other stateful service, keep a separate backup. The script and DPanel can guarantee "the container is back on the old image"; they cannot guarantee "the data is back in the old state".

### It only handles "one new version"

If upstream jumps several versions at once, this round only reaches the newest one and does not step through them one by one. Upgrades across major versions (for example a database schema that requires a migration per version) have to be arranged by you.

### Where the images come from is not the script's business

The script **does not touch the registry**: the registry is decided by the Docker daemon, DPanel and your own configuration. That is why mechanisms such as "several GitHub mirror sites racing in parallel" are neither needed nor implemented under the v2.0.0 architecture.

## 8. What the scene looks like after a failure

### Error lines go to stdout and to the real stderr

When a scheduled task (DPanel) **fails** it keeps only stderr and discards stdout. So the `ERR` / `CRITICAL` lines (and the indented follow-up lines right after them) are written **twice**: the complete log goes to stdout, and the failure reason additionally goes to the real stderr. That way the scheduled task is not left with nothing but a bare `exit status 1`, and **the log always carries the reason** (which is also the first thing to look at when investigating a failure).

DPanel's original error text is **passed through** into the log; the script does not rewrite it. See [the parameter docs](parameters.en.md#where-the-failure-reason-is-written).

### Exit codes

| Exit code | The scene |
|---|---|
| `0` | Success (including "already up to date" and `--dry-run`) |
| `1` | Failure: DPanel reported an error, the project is not registered, the remaining budget is not enough, a dependency is missing, a parameter is wrong. The target is left as it was |
| `2` | Reserved. Not produced in v2.0.0 for now (DPanel owns the rollback, the script does not see it) |
| `3` | **A breaking change**: your invocation is no longer valid. The script stopped before doing anything and changed nothing; just follow the migration path in the log and fix the command |
| `130` | Interrupted by Ctrl-C (SIGINT) |
| `143` | Killed by `timeout` / SIGTERM (common when a DPanel scheduled task hits its execution timeout) |

## 9. Differences from v1.x

| Aspect | v1.x | v2.0.0 |
|---|---|---|
| Who pulls the image | The script itself through the Docker Engine API, watching byte counters, judging stalls and retrying | DPanel and the Docker daemon (the script does not touch the registry) |
| Who rebuilds the container | The script itself, from the declarative configuration, verifying the specification item by item | DPanel's `container:upgrade` |
| Who rebuilds the Compose project | The script itself: `docker compose up -d --force-recreate` | DPanel's `compose:deploy` |
| Rollback point | The tag `<image repository>:prev` (one copy kept) | DPanel's backup container `<container name>-bak-<timestamp>` (container mode) |
| Health gate | The script judged it itself (healthcheck / a 30 second observation window) | DPanel's upgrade flow owns it, the script no longer judges |
| Bad-version pinning | `<image repository>:bad`, 7 days by default | Removed |
| Failure reason | stdout + the real stderr | Unchanged (stdout + the real stderr) |
| Transaction directory | `--state-dir` / `STATE_ROOT`, keeping the rollback scene | Removed |
| Mutex lock | Already removed (concurrency is left to the DPanel scheduled task) | Unchanged: there is no lock inside the script |
| Pull control parameters | `--pull-retries`, `PULL_RETRIES`, `DIGEST_RETRIES`, `T_STALL`, `T_STALL_FINISH` and more | All obsolete (DPanel owns the pull) |
| Cross-version notice | `lastver` under `COMPAT_ROOT` | Unchanged |

Removed parameters and environment variables (matching one aborts with exit code `3`):

- Parameters: `--compose-dir`, `--state-dir`, `--bad-ttl-days`, `--pull-retries`.
- Environment variables: `STATE_ROOT`, `BAD_TTL_DAYS`, `PULL_RETRIES`, `DIGEST_RETRIES`, `DIGEST_RETRY_WAIT`, `T_STALL`, `T_STALL_FINISH`, `T_PULL_MAX`, `T_UP`, `T_HEALTH`, `HEALTH_TRIES`, `T_ROLLBACK`, `PLAIN_BOOT`, `COMPOSE_DIR`, `COMPOSE_BASE`.
- Exception: `T_INSPECT` is still accepted, equivalent to `DP_T_CHECK`.

In addition, v2.0.0 **no longer produces** the `<image repository>:prev` tag or the `/tmp/.container-autoupdate/compose-*` transaction directories; you can clean them up by hand after upgrading (the diagnostic script `scripts/ct-stale-lock-check.sh` lists them).

For migration and version policy see [README](../README.en.md#versions-and-upgrades).
