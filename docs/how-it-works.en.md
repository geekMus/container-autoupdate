# How it works and where its safety limits are

> Language: [English](how-it-works.en.md) | [中文](how-it-works.md)

> This page explains **how the script does things**, **when it refuses to act**, and **what it cannot protect**. Three minutes spent on it before use is three minutes well spent.

## 1. What it does, in one sentence

Since v2.0.0 the script **no longer pulls images and no longer rebuilds containers itself**: it does exactly three things —

1. **decide whether this target needs an update** (container mode = ask DPanel; Compose mode = the pull itself is the decision);
2. **hand the update action over to be executed**;
3. **report the outcome truthfully** (success / failure / nothing to do).

"Handing over" has two paths (since v2.1.0 Compose takes the second one and no longer goes to DPanel):

| Update target | Handed to | What the script actually runs |
|---|---|---|
| Container (`--container <name>`) | DPanel | `container:upgrade` (check first; add `--upgrade` only when there really is a new version) |
| Compose project (`--compose <project>`) | docker compose itself | `docker compose pull` + `docker compose up -d` |

Why the split:

- Rebuilding a container means **faithfully reproducing** its network, mounts (including the real names of anonymous volumes), resource limits, restart policy, capabilities… miss one and it is a production incident. v1.x spent over a thousand lines on this and still hit things like "a pull mistaken for a stall" and "the failure reason printed twice". DPanel already has a mature implementation, and **it rolls back by itself when an upgrade fails**.
- A Compose project needs no rebuilding by the script: compose itself records "which containers this project has, which compose file it uses, where its working directory is" in container labels, and `pull` + `up -d` is its standard way of working. So the project **need not be registered in the DPanel web UI first**, and the `--pull-image` default-value trap of DPanel's `compose:deploy` no longer applies.
- The rollback point is no longer a `<image repository>:prev` tag maintained by the script, so "the rollback point silently deleted by cleanup logic" cannot happen either.
- The script therefore shrank from 1700+ lines to a few hundred: a smaller logic surface, and every line that remains can be read and verified at a glance.

## 2. Prerequisites

- **Container mode needs DPanel**: the update action relies on the DPanel CLI (`container:upgrade`). Running **inside the DPanel container** is recommended (a DPanel scheduled task runs inside the `dpanel` container by default), where the script executes `/app/server/dpanel` directly; run anywhere else and the script switches to `docker exec <dpanel container> /app/server/dpanel ...`, with the container name given by `--dpanel-container` (default `dpanel`) and the path by `--dpanel-bin`. **When not running inside the dpanel container, the `docker` command is additionally required.**
- **Compose mode needs no DPanel**: what it wants is the `docker` command and the **Compose v2 plugin** (`docker compose`, not `docker-compose`), and the project **need not be registered in DPanel first**. The project directory and compose file are looked up backwards from container labels by default; only when that fails do `--compose-dir` / `COMPOSE_DIR` serve as the fallback.
- Dependency commands: `timeout` `sed` `awk` `grep` (busybox or coreutils, either is fine). **`curl` and `flock` are no longer needed.**
- The script first verifies that `docker version` can connect, then, in Compose mode, that `docker compose version` works — whichever link is missing is the link reported, so you are not pointed at an unrelated line of investigation.

Parameters and environment variables: see the [parameters documentation](parameters.en.md#all-command-line-parameters).

## 3. What happens in one round

```
1. Parse arguments
2. Compatibility check: an old flag / old environment variable hits → abort with the migration path (exit code 3)
   --compat <version> declares "only validate up to some version" → a newer breaking change is a hard stop
3. Cross-version WARN: this target last ran an older version, and a behavior-level change lies in between → print the notice, carry on
4. Dependency check:
     timeout / sed / awk / grep;
     Compose mode (or not running inside the dpanel container) needs docker, and Compose mode also needs the docker compose v2 plugin;
     container mode probes the DPanel CLI once more (dp_cli version)
5. Write lastver (the record that "this target has seen the current version")
6. Run the update by mode:
     container       → container:upgrade (check only first, without --upgrade)
     Compose project → docker compose pull + docker compose up -d
7. Report (OK / ERR / WARN / DRY)
8. Exit
```

Three orderings are deliberate:

- **The compatibility check comes before the dependency check** — when a way of calling the script has stopped working, you must see the migration guidance first, rather than being pointed at an unrelated line of investigation by a "cannot find docker / cannot find the DPanel CLI" message.
- **The cross-version `WARN` is printed before the dependency check, but `lastver` is written only after it** — a round that fails on missing dependencies does not count as "the user has been told", so the notice is not swallowed permanently.
- **`lastver` is written before the update action actually runs** — reaching the update logic at all means the notice has arrived in front of the user; whether the update itself succeeds makes no difference to that.

See lines 918–971 of `container-autoupdate.sh` for the main flow.

## 4. The full container-mode (`--container`) flow

Implementation: `container_update()` (lines 639–693 of `container-autoupdate.sh`). The branch first prints one line, `MODE container 容器=<name>`.

1. `container:upgrade --name <container> --docker-env local` (**without** `--upgrade`) = **check only**. DPanel compares the remote and local digests itself and returns JSON:

   ```json
   {"upgrade":true,"digest":"sha256:a5c10db1...","digestLocal":["ghcr.1ms.run/yetone/magpie@sha256:d9d64cc1..."],"error":"","message":"","status":"upgrade"}
   ```

2. `upgrade` is **not** `true` → that is "already up to date". The script prints `OK 容器 <name> 已是最新（DPanel 报告 status=latest）`, exits `0`, and **has not touched the container at all**.

   ```text
   [2026-11-03 16:38:08] OK 容器 myapp 已是最新（DPanel 报告 status=latest）
       → OK: container myapp is already up to date (DPanel reports status=latest)
   ```

3. `--dry-run` → it really asks DPanel once; when a new version is found it only prints, and does not upgrade, exit code `0`:

   ```text
   [2026-11-03 16:38:08] 发现新版本（远端 digest=sha256:a5c10db1...）
   [2026-11-03 16:38:08] DRY 只检查不动手，本轮不升级
       → new version found (remote digest=sha256:a5c10db1...)
       → DRY: check only, no action taken; this round does not upgrade
   ```

4. Not enough time left (`< DP_MIN_UPGRADE`, 90 seconds by default) → **no action**, exit code `1`:

   ```text
   [2026-11-03 16:38:08] WARN 剩余时间不足（40s < 90s），本轮不启动升级，容器保持原样
   [2026-11-03 16:38:08]      下一轮计划任务会重新检查；也可以把 T_HARD 或计划任务的超时调大
       → WARN: not enough time left (40s < 90s); the upgrade is not started this round and the container is left as is
       →      the next scheduled task will check again; you can also raise T_HARD or the timeout of the scheduled task
   ```

5. A real upgrade adds `--upgrade`: `container:upgrade --name <container> --upgrade --docker-env local`. The script first prints the wait limit; on success DPanel returns `{"containerId":"..."}` and the script prints `OK DPanel 已完成升级（containerId=...）`, exit code `0`:

   ```text
   [2026-11-03 16:38:08] 交给 DPanel 升级（等待上限 420s；新容器起不来时 DPanel 会自行回滚）
   [2026-11-03 16:38:08] OK DPanel 已完成升级（containerId=3f2a9c1b7d5e）
       → handing the upgrade to DPanel (waiting at most 420s; when the new container will not start, DPanel rolls back by itself)
       → OK: DPanel finished the upgrade (containerId=3f2a9c1b7d5e)
   ```

6. **The rollback point is the backup container DPanel creates**, named like `<container name>-bak-<timestamp>` (for example `myapp-bak-20261103163808`): it runs the pre-upgrade image and sits in the Exited state. To roll back, rename it back (the DPanel web UI shows this backup container directly):

   ```sh
   docker stop myapp && docker rm myapp
   docker rename myapp-bak-20261103163808 myapp
   docker start myapp
   ```

7. **When an upgrade fails, DPanel rolls back by itself** (measured: with a broken image the container stays on the old image and the backup container remains). The script reports the failure with exit code `1` and DPanel's original error text in the log:

   ```text
   [2026-11-03 16:38:08] ERR DPanel 升级失败：镜像拉取失败
   [2026-11-03 16:38:08]     容器保持原样；DPanel 若已重建过会自行回滚（备份容器 <容器名>-bak-<时间戳>）
       → ERR: the DPanel upgrade failed: the image pull failed
       →      the container is left as is; if DPanel had already rebuilt it, it rolls back by itself (backup container <container name>-bak-<timestamp>)
   ```

> The **biggest difference** from v1.x in container mode: the rollback point is no longer a `:prev` image tag but DPanel's backup container. The script **never passes** `--disable-bak`, so keeping a backup is the default behaviour.

### A DPanel outcome may only be judged by parsing JSON

The **exit code of the DPanel CLI cannot be trusted**: measured failures such as "container does not exist" and "image list unreadable" still exit `0`. The script's failure condition is **`code` ≥ 400, or `status=failed`, or a non-empty `error` field** — not "`code` is not 200". Conversely, on success (for example `{"containerId":"..."}`) there is **no `code` field at all**, and treating that as a failure signal would misjudge a success as a failure.

Two more rules for reading results: the script **does not pass `-q` / `--quiet`** when calling DPanel (it swallows the result JSON along with everything else); it takes the result from "the **last** line of stdout starting with `{`"; and it does **not truncate `error` text at a comma** (DPanel's error text contains commas, and once truncated the real reason is lost).

## 5. The full Compose-mode (`--compose`) flow

Implementation: `compose_update()` (lines 808–916 of `container-autoupdate.sh`) and `compose_locate()` (lines 747–775). The branch first prints one line, `MODE compose 项目=<project>`.

1. **Recognise the project**: look it up backwards from container labels first — `docker ps -a --filter label=com.docker.compose.project=<project>` takes the first container, then `docker inspect` reads three labels: `com.docker.compose.project.working_dir` (directory), `com.docker.compose.project.config_files` (compose file), `com.docker.compose.project.environment_file` (env file). **Only when the lookup fails** (the project does not have a single container) do `--compose-dir` / `COMPOSE_DIR` serve as the fallback; with neither, exit code `1`:

   ```text
   [2026-11-03 16:38:08] ERR 找不到 Compose 项目 myapp 的项目目录
   [2026-11-03 16:38:08]     当前 Docker 里没有带「myapp」这个 compose 项目标签的容器，反查不到
   [2026-11-03 16:38:08]     处理方式二选一：
   [2026-11-03 16:38:08]       1) 用 --compose-dir <路径> 指定 compose 文件所在目录
   [2026-11-03 16:38:08]       2) 确认项目名写法；项目还没部署过就先手动 compose up 一次
       → ERR: cannot find the project directory of Compose project myapp
       →      no container in the current Docker carries the "myapp" compose project label, so it cannot be looked up backwards
       →      two ways out:
       →        1) name the directory holding the compose file with --compose-dir <path>
       →        2) check how the project name is written; if the project has never been deployed, run compose up once by hand
   ```

   The directory was found but does not exist → `ERR Compose 项目目录不存在：<path>`, exit code `1`.

2. **List the images this project involves**: `docker compose config --images`, printing `    目录=<directory>` first (and `    文件=<file>` when there is a compose file), then `    镜像: <image reference>` per line. If the list cannot be read, one warning is printed and the flow carries on rather than aborting.

   ```text
   [2026-11-03 16:38:08]     目录=/opt/myapp
   [2026-11-03 16:38:08]     文件=/opt/myapp/compose.yaml
   [2026-11-03 16:38:08]     镜像: ghcr.1ms.run/yetone/magpie:latest
   [2026-11-03 16:38:08] WARN docker compose config 没能读出这个项目的镜像清单（退出码 1），继续按流程走
       → WARN: docker compose config could not read this project's image list (exit code 1); carrying on with the flow
   ```

3. **`--dry-run`: list the images, then exit `0`**, with nothing pulled or deployed this round:

   ```text
   [2026-11-03 16:38:08] DRY 只检查不动手：上面是这个项目涉及的镜像，本轮不拉取、不部署
   [2026-11-03 16:38:08]     要真正更新就去掉 --dry-run（拉取本身就是「有没有新版本」的判断）
       → DRY: check only, no action: the lines above are the images this project involves; nothing is pulled or deployed this round
       →     to actually update, drop --dry-run (the pull itself is the "is there a new version" decision)
   ```

4. **Budget gate**: remaining time `< DP_MIN_UPGRADE` (90 seconds by default) → no deploy, exit code `1`:

   ```text
   [2026-11-03 16:38:08] WARN 剩余时间不足（40s < 90s），本轮不部署，项目保持原样
       → WARN: not enough time left (40s < 90s); nothing is deployed this round and the project is left as is
   ```

5. **Take a snapshot**: record "container **name** → image id" (`docker ps -a` + `docker inspect`) to compare against after the deploy. The key must be the container name, not the container ID — `up -d` gives rebuilt containers a new ID, so keying by ID would classify every rebuilt container as "created" and never report "rebuilt" (hit on real hardware on the N1 box).

6. **The pull**: `docker compose pull`, wait limit `DP_T_PULL` (420 seconds by default). On failure it does **not deploy**, the project is left as is, exit code `1`, and compose's own last 5 lines are pasted verbatim into the log:

   ```text
   [2026-11-03 16:38:08] 拉取镜像（docker compose pull，等待上限 420s）
   [2026-11-03 16:38:08] ERR 拉取失败（docker compose pull 退出码 1），本轮不部署，项目保持原样
       → pulling images (docker compose pull, waiting at most 420s)
       → ERR: the pull failed (docker compose pull exited with 1); nothing is deployed this round and the project is left as is
   ```

   Failing to enter the project directory is a separate failure: `ERR 无法进入 Compose 项目目录：<path>`.

7. **Redeploy in place**: `docker compose up -d`, wait limit `DP_T_UP` (180 seconds by default). **Never `--remove-orphans`** (it deletes containers that are not in the current compose file — a data incident). On failure, exit code `1`:

   ```text
   [2026-11-03 16:38:08] 就地重新部署（docker compose up -d，等待上限 180s）
   [2026-11-03 16:38:08] ERR 重新部署失败（docker compose up -d 退出码 1）
   [2026-11-03 16:38:08]     compose 文件与容器定义都没被脚本改过，可以直接再跑一轮
       → redeploying in place (docker compose up -d, waiting at most 180s)
       → ERR: the redeploy failed (docker compose up -d exited with 1)
       →      neither the compose file nor the container definitions were changed by the script; you can run another round right away
   ```

8. **Report truthfully**: compare against the snapshot from step 5 and state three cases separately — **rebuilt** (the image id changed), **created** (the container did not exist before the deploy: a first deploy, or a service newly added to the compose file), and nothing changed at all:

   ```text
   [2026-11-03 16:38:08]     已重建：myapp-web（3f2a9c1b7d5e → 8c1d4e6a9f02）
   [2026-11-03 16:38:08]     新建：myapp-worker（8c1d4e6a9f02）
   [2026-11-03 16:38:08] OK Compose 项目 myapp 已重新部署（1/3 个容器换了镜像，1 个新建）
       →      rebuilt: myapp-web (3f2a9c1b7d5e → 8c1d4e6a9f02)
       →      created: myapp-worker (8c1d4e6a9f02)
       → OK: Compose project myapp was redeployed (1/3 containers switched images, 1 created)
   ```

   The summary line is one of four:

   | Case | Summary line |
   |---|---|
   | Some containers switched images, and some were created | `OK Compose 项目 <名> 已重新部署（N/M 个容器换了镜像，K 个新建）` |
   | Only containers switched images | `OK Compose 项目 <名> 已重新部署（N/M 个容器换了镜像）` |
   | Only creations | `OK Compose 项目 <名> 已部署（K 个容器新建）` |
   | Nothing changed at all | `OK Compose 项目 <名> 已是最新（拉取后没有容器需要重建）` |

   Finally it checks once **whether any container is not running** (skipped when the project has no containers at all):

   ```text
   [2026-11-03 16:38:08] ERR 有容器没在运行（2/3 running）：
   [2026-11-03 16:38:08]     myapp-worker exited
   [2026-11-03 16:38:08]     compose 文件没被改过；用 docker compose logs <服务名> 看具体原因
       → ERR: some containers are not running (2/3 running):
       →      myapp-worker exited
       →      the compose file was not changed; use docker compose logs <service name> to see the reason
   ```

   A container not running → exit code `1`; all running → one line, `    运行状态：3/3`, exit code `0`.

### Why Compose mode needs no registration in DPanel

DPanel's `compose:deploy` only recognises projects registered in its web UI (that was the v2.0.0 route, which is why registering or importing once was required back then). No DPanel takes part in this route now: compose itself knows which containers the project has and which file it uses, and the script merely runs `docker compose` in that directory.

### The pull itself is the "is there a new version" decision

Compose mode **has no "check only" step**: the script does no image digest comparison, and whether `docker compose pull` really brought something new down is the basis for "should this round rebuild"; with no new version it is a very fast no-op. That is why these logs never make a prediction like "a new version was found" — only container mode (where DPanel really goes and checks) has that.

### Only compose's own pull / up -d

- No manual `docker tag`, no manual `docker create`, **nothing is deleted**; rebuilding is compose's job.
- Compose parameters always travel as environment variables `COMPOSE_PROJECT_NAME` / `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` / `COMPOSE_ENV_FILES`, never spliced into the command line — with a path containing spaces, compose prints Usage yet returns `0` (a silent error).
- The existing project name, compose file and env file are preserved; the working directory is exactly the one found by the reverse lookup (relative paths inside the compose file resolve against it).

## 6. When it skips or does not act

None of these are faults; the script (or DPanel) is deliberately not acting. The log states the specific reason.

| Case | Outcome |
|---|---|
| Container mode: DPanel reports `status=latest` (`upgrade` is not `true`) | Prints `OK 容器 <名> 已是最新…`, exit code `0`, the container is untouched |
| Container mode `--dry-run` | Really asks DPanel once, prints only the new version it found, exit code `0`, no upgrade |
| Compose mode `--dry-run` | Only lists the images the project involves, exit code `0`, nothing pulled or deployed |
| Not enough time left (`< DP_MIN_UPGRADE`, 90 seconds by default) | No action, exit code `1`, the target is left as is (containers and projects each have their own wording) |
| The Compose project's directory cannot be found backwards and no `--compose-dir` was given | Prints `ERR 找不到 Compose 项目 <名> 的项目目录` + the two ways out, exit code `1` |
| The Compose project directory does not exist | Prints `ERR Compose 项目目录不存在：<路径>`, exit code `1` |
| A container is not running (after a Compose-mode deploy) | Names each one + `ERR 有容器没在运行（R/M running）`, exit code `1` |
| An old parameter / old environment variable hits `BREAKING_TABLE` | Aborts immediately, exit code `3`, nothing was changed, the new way is in the log |
| A dependency command is missing (`timeout` `sed` `awk` `grep`) | Prints `ERR 缺少依赖命令：…`, exit code `1` |
| `docker` cannot connect | Prints `ERR 无法连接 Docker（DOCKER_HOST=…）`, exit code `1` |
| Compose mode without the Compose v2 plugin | Prints `ERR 无法执行 docker compose（缺 compose 插件？）`, exit code `1` |
| Container mode cannot reach the DPanel CLI (`dp_cli version` produced nothing) | Prints `ERR 无法调用 DPanel CLI（…）`, exit code `1` |
| Both `--compose` and `--container` given, or neither | Prints `ERR 必须且只能指定一个目标…`, exit code `1` |

Old parameters: `--state-dir`, `--bad-ttl-days`, `--pull-retries` (`--compose-dir` **is usable again**); for the old environment variables see the [parameters documentation](parameters.en.md#all-environment-variables).

## 7. What it cannot protect (important)

### Compose mode cannot "check only whether a new version exists"

On this route the script queries no digests: **the pull itself is the decision**. So `--dry-run` can only list which images this project involves — it pulls nothing and deploys nothing, and therefore will not tell you "whether there is a new version". To see in advance whether a new version exists, you can only use container mode (`--container`, where DPanel really goes and checks), or run a round against a test project first.

### Compose mode creates no backup container and maintains no `:prev`

On this route compose creates no backup container, and the script no longer tags `:prev` itself. Rollback depends solely on "the old image is still local" — the old image id can be seen in the previous round's log line `已重建：<名>（旧12位 → 新12位）`, or found in `docker images`:

```sh
# when the old image is still local
docker tag <旧镜像ID> <镜像仓库>:latest
docker compose up -d --force-recreate
```

Container mode is the opposite: DPanel leaves a `<container name>-bak-<timestamp>` backup container (restorable directly in the web UI). DPanel's `--disable-bak` is **never passed**, so a backup is the default.

### Who stops a bad image

The script **does not judge whether the image it pulled is a bad version**. Container mode relies on DPanel (it rolls back by itself when the new container will not start); Compose mode relies on "a failure means no deploy" plus "containers that will not start get named" — the script only reports the facts.

### Health and business correctness are not the script's job

The script guarantees exactly two things: **the compose command succeeded**, and **the containers are running**. It does not run healthchecks, does not wait and watch for a number of seconds, and does not verify that the service is genuinely usable. That closing line in Compose mode, `运行状态：R/M`, only says that R containers are in the running state — not that the service is available.

### Data is not rolled back

Rollback restores **containers and images** only. Migrations, writes and schema changes a new version has already made to data volumes or databases are **not** undone by a rollback.

> For containers running databases or stateful services, please keep a separate backup. The script and DPanel can guarantee "the container goes back to the old image"; they cannot guarantee "the data goes back to its old state".

### It handles one new version at a time

If upstream skipped several versions at once, this round goes only to the newest one and does not step through them one by one. Upgrades across major versions (where a database schema demands version-by-version migration, say) need to be arranged by you.

### Where images come from is not the script's business

The script **does not touch the registry**: pulling images is handed to docker / the daemon and the registry, using the setup you configured (Docker's registry-mirror, DPanel's settings). So mechanisms like "racing several GitHub mirrors in parallel" are **no longer needed, and are not implemented**: which source is fast and which one connects is docker's business, and the script has no control over it.

(For comparison: the part of the scheduled task that downloads "the script itself" uses "try the second URL only if the first fails", which is not parallel racing either — for a file under 50KB, two sequential attempts are already fast enough.)

## 8. What a failure looks like

### Error lines go to stdout and to the real stderr

A scheduled task (DPanel) keeps only stderr and discards stdout when the task **fails**. So `ERR` / `CRITICAL` lines (and the indented continuation lines that immediately follow them) are written **twice**: the complete log to stdout, and the failure reason additionally to the real stderr. That way the scheduled task does not end up with nothing but a bare `exit status 1`, and **there is always a reason in the log** (which is also the first thing to reach for when investigating).

When reporting an error the script also pastes what the update executor itself said: in container mode DPanel's original error text (**passed through**; the script does not rewrite it), in Compose mode the last 5 lines of compose's own output verbatim. See the [parameters documentation](parameters.en.md#where-the-failure-reason-is-written).

### Exit codes

| Exit code | Scene |
|---|---|
| `0` | Success (including "already up to date" and `--dry-run` in both modes) |
| `1` | Failure: DPanel reported an error, the Compose project directory was not found or could not be entered, the pull or the deploy failed, a container is not running, not enough budget left, a dependency is missing, a parameter is wrong. The target is left as is |
| `2` | Reserved. The current version never produces it: container rollback is DPanel's job; Compose mode does not deploy on failure, so it cannot leave a half-new project behind |
| `3` | **Breaking change**: the way you call the script no longer works. The script stops before doing anything, changes nothing, and you follow the migration path in the log |
| `130` | Interrupted by Ctrl-C (SIGINT) |
| `143` | Killed by `timeout` / SIGTERM (common when a DPanel scheduled task times out) |

## 9. How it differs from v1.x

| Aspect | v1.x | Current version |
|---|---|---|
| Who pulls images | The script itself, over the Docker Engine API, watching progress bytes, judging stalls, retrying | Container mode hands it to DPanel; Compose mode hands it to `docker compose pull` / the daemon (the script does not touch the registry) |
| Who rebuilds containers | The script itself, from the declarative config, verifying the spec item by item | DPanel's `container:upgrade` |
| Who rebuilds a Compose project | The script itself, `docker compose up -d --force-recreate` | The script calls `docker compose up -d` and compose rebuilds (with **no** `--remove-orphans`) |
| Must a Compose project be registered in DPanel first | Not involved (the script handled everything) | No (v2.0.0 required registration; since v2.1.0 it does not) |
| Rollback point | A `<image repository>:prev` tag (one copy kept) | Container mode: DPanel's backup container `<container name>-bak-<timestamp>`; Compose mode: no backup container, relying on the local old image |
| Health gate | The script judged it itself (healthcheck / watching 30 seconds) | In container mode DPanel's upgrade flow does; in Compose mode the script only confirms "the containers are running" |
| Pinning a bad version | `<image repository>:bad`, 7 days by default | Removed |
| Failure reason | stdout + the real stderr | Unchanged (stdout + the real stderr) |
| Transaction directory | `--state-dir` / `STATE_ROOT`, keeping the rollback scene | Removed |
| Mutex lock | Already removed (concurrency rests on DPanel scheduled tasks) | Unchanged: the script takes no lock internally |
| Pull-control parameters | `--pull-retries`, `PULL_RETRIES`, `DIGEST_RETRIES`, `T_STALL`, `T_STALL_FINISH` and more | All removed (pulling is DPanel's / docker compose's job) |
| Cross-version notice | `lastver` under `COMPAT_ROOT` | Unchanged |

Removed parameters and environment variables (hitting one aborts, exit code `3`):

- Parameters: `--state-dir`, `--bad-ttl-days`, `--pull-retries`.
- Environment variables: `LOCK_PREFIX`, `STATE_ROOT`, `BAD_TTL_DAYS`, `PULL_RETRIES`, `DIGEST_RETRIES`, `DIGEST_RETRY_WAIT`, `T_STALL`, `T_STALL_FINISH`, `T_PULL_MAX`, `T_UP`, `T_HEALTH`, `HEALTH_TRIES`, `T_ROLLBACK`, `PLAIN_BOOT`, `COMPOSE_BASE`.
- Exception one: `T_INSPECT` is still accepted, as an equivalent of `DP_T_CHECK`.
- Exception two: `--compose-dir` and `COMPOSE_DIR` **are usable again** (Compose mode uses them as the fallback for the project directory).
- New time-budget environment variables: `DP_T_PULL` (the Compose pull, 420 seconds by default) and `DP_T_UP` (the Compose deploy, 180 seconds by default); `DP_T_CHECK` / `DP_T_UPGRADE` / `DP_MIN_UPGRADE` keep their meaning.

Also, the `<image repository>:prev` tag and the `/tmp/.container-autoupdate/compose-*` transaction directory are no longer produced; you can clean them up by hand after upgrading (the inspection script `scripts/ct-stale-lock-check.sh` lists them).

Migration and version policy: see the [README](../README.en.md#versions-and-upgrades).
