# container-autoupdate

> Language: [English](README.en.md) | [中文](README.md)

A single-file container auto-update script for **DPanel scheduled tasks**.

One run = one check: the script does exactly three things — decide whether an update is due, perform the update action, and report the result faithfully. **The script contains no scheduler** — the frequency, the start/stop control and the concurrency are all delegated to DPanel's "scheduled task".

> Each of the two paths plays to its own strength: **a plain container is handed to DPanel**, while **a Compose project is handed to Docker's own Compose command**. Rebuilding a container means reproducing its network, mounts (including the real names of anonymous volumes), resource limits, restart policy, capabilities and much more, and missing one of them is a production incident; DPanel already does all of that properly, and on a failed upgrade it rolls back by itself and leaves a ready-made backup container behind. A Compose project, on the other hand, carries all the information about which containers belong to it, which Compose file it uses and how to rebuild them, so `docker compose pull` + `docker compose up -d` is simply its standard procedure. The script therefore shrank from 1700-odd lines to around 700, with a small, controllable surface.

> Running it by hand is allowed too; that is a one-off run that ends when it is done. It is **not recommended** to wrap it in another timer such as cron or a systemd timer — concurrency is guaranteed by the DPanel scheduled task, one scheduled task per target.

## Two modes

| How your container was started | Which argument to use | What the script actually runs |
|---|---|---|
| `docker compose up -d` | `--compose <project-name>` | `docker compose pull` + `docker compose up -d` (redeploy in place) |
| `docker run ...` | `--container <container-name>` | `dpanel container:upgrade --name <container-name>` (it checks first and adds `--upgrade` only when an upgrade is needed) |

**Container mode** just hands the target name to DPanel and does nothing else.

**Compose mode** does not go through DPanel. It first identifies the project inside Docker: it finds a container of the project with
`docker ps -a --filter label=com.docker.compose.project=<project-name>`, then reads three Compose labels off it —
`com.docker.compose.project.working_dir` (working directory), `com.docker.compose.project.config_files` (Compose file) and
`com.docker.compose.project.environment_file` (env file). Only when that lookup fails (the project has not a single container) does it fall back to `--compose-dir <path>`
(**available again as of v2.1.0**). With the directory known, it runs Compose's own `pull` and `up -d` there, and then reports faithfully which containers changed image and whether any container failed to come up.

> Why Compose does not go through DPanel: **the project does not have to be registered in the DPanel web UI first**, and you do not have to
> deal with the `--pull-image` default-value trap of `compose:deploy` (the default `command` never pulls a new image, so you end up with
> "the deployment succeeded but the version did not change"). The script only runs `docker compose pull` + `docker compose up -d` and
> **never adds `--remove-orphans`** — that would delete containers that are not in the current Compose file, which is a data incident.

> Pulling from the registry is entirely delegated to the Docker daemon / DPanel, using **the registry mirrors that you and the daemon configured**; the script never touches a registry at all — so "racing several mirror prefixes in parallel" is no longer needed.

## Prerequisites

- **Container mode** requires **DPanel** on the target machine: the upgrade action relies on DPanel's own command line (the `container:upgrade` that ships with DPanel 1.11.x).
- **Run it inside DPanel's dpanel container**: DPanel's "scheduled task" executes inside that container by default, so the script calls the `/app/server/dpanel` binary right there, and Docker operations reach the host daemon through the `/var/run/docker.sock` mounted into the container. This project is positioned as "one DPanel scheduled task" and **does not offer a host-side way to run it**.
- **Compose mode additionally needs `docker` and the Compose v2 plugin** (`docker compose`, not `docker-compose`): the dpanel container ships the docker CLI; when the plugin is unavailable the script prints `ERR 无法执行 docker compose（缺 compose 插件？）` and exits `1`.
- **A Compose project does not have to be registered in the DPanel web UI**: the script looks the project directory and the Compose file up from the container labels by project name; when that lookup fails, point at the directory with `--compose-dir <path>`, or run `docker compose up -d` by hand once so that the labels land on the containers.
- Required commands: `timeout` `sed` `awk` `grep` (busybox or coreutils both work); Compose mode additionally needs `docker`. The script itself **needs neither `curl` nor `flock`** — `curl` is only used by the download command inside the scheduled task.

## Quick start

### DPanel scheduled task

Create a scheduled task and paste the whole block below into the script box (**one script is enough** — there is no bootstrapper since v3.0.0):

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

For a plain container, replace the last line with `--container mycontainer`.

> What this does: downloads to a temporary file → verifies it (not an empty file, syntax is fine, it really is this script) → only then overwrites `/tmp/container-autoupdate.sh` → runs it. **If the download fails, the previous copy is kept and still runs**, so a flaky network does not waste the round.
>
> Set the execution timeout to **≥ 600 seconds** (the script's own hard limit is 540 seconds).
>
> **Why not `curl ... | sh`**: a pipe swallows `curl`'s failure (the task log gives no hint that the round never ran). The block above downloads to disk, verifies, then executes, and returns non-zero explicitly on failure.
>
> **Pinning a version**: replace `latest/download` in both URLs with `download/v3.0.0` (tags are listed on the [Releases](https://github.com/geekMus/container-autoupdate/releases) page). Pinning is optional — a breaking change makes the script stop by itself and write the reason and the fix into the log.

### Run one round manually

To check once in a while, run it inside the dpanel container (it ends when it is done, nothing stays resident):

```sh
docker exec -it dpanel sh -c 'curl -fsSL --max-time 60 https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh -o /tmp/container-autoupdate.sh && sh /tmp/container-autoupdate.sh --compose myapp --dry-run'
```

> It is not recommended to schedule this with cron or a systemd timer: two rounds for the same target running at the same time will step on each other. If you want scheduled updates, use a DPanel scheduled task — one scheduled task per target is enough.

## How the script updates itself

| Situation | Behaviour |
|---|---|
| The remote has a new version | Downloads to `/tmp/ct-new.sh`, verifies it, overwrites `/tmp/container-autoupdate.sh`, then runs it |
| The remote is still the same version | Downloads anyway (under 50KB, one or two seconds), verifies, overwrites, behaviour unchanged |
| Download failed (source down, no network) | **Keeps the previous copy and runs it**; `curl`'s error shows in the log |
| What arrived is garbage (HTML redirect page, truncated file) | Three checks stop it (size > 1000, `sh -n`, contains the signature string), **nothing is overwritten**, the old copy keeps running |
| Nothing ever succeeded (first install while offline) | Fails loudly with `ERR 拿不到可用的更新脚本`, exit code 1 — never a silent success |

> The version is on the first log line: `container-autoupdate v3.0.0 启动`; `--version` prints it too.

## Common commands

```sh
container-autoupdate.sh --container mycontainer --dry-run   # container mode: ask DPanel whether a new version exists, change nothing
container-autoupdate.sh --container mycontainer             # upgrade a plain container
container-autoupdate.sh --compose myapp                     # redeploy a Compose project in place (no DPanel registration needed)
container-autoupdate.sh --compose myapp --compose-dir /opt/myapp   # when the project directory cannot be looked up
container-autoupdate.sh --dpanel-container mydpanel --container mycontainer   # when the DPanel container is not called dpanel
```

**`--dry-run` behaves differently in the two modes:**

- **Container mode**: it really asks DPanel whether a new version exists, but does not perform the upgrade. With a new version it prints a "new version found" line, without one it prints "already up to date":

```text
[2026-11-03 06:00:12] 发现新版本（远端 digest=sha256:a5c10db1...）
[2026-11-03 06:00:12] DRY 只检查不动手，本轮不升级

→ a new version was found (remote digest=sha256:a5c10db1...)
→ DRY: check only, hands off; no upgrade this round
```

- **Compose mode**: it only lists the images this project uses, then exits `0`; **it pulls nothing and deploys nothing**. Compose has no "check whether a new version exists" ability — the pull itself is the decision:

```text
[2026-11-03 06:00:12] MODE compose 项目=myapp
[2026-11-03 06:00:12]     目录=/opt/myapp
[2026-11-03 06:00:12]     文件=/opt/myapp/compose.yaml
[2026-11-03 06:00:12]     镜像: ghcr.1ms.run/yetone/magpie:latest
[2026-11-03 06:00:12] DRY 只检查不动手：上面是这个项目涉及的镜像，本轮不拉取、不部署
[2026-11-03 06:00:12]     要真正更新就去掉 --dry-run（拉取本身就是「有没有新版本」的判断）

→ MODE compose project=myapp
→     directory=/opt/myapp
→     file=/opt/myapp/compose.yaml
→     image: ghcr.1ms.run/yetone/magpie:latest
→ DRY: check only, hands off; the images above are what this project uses; nothing is pulled or deployed this round
→     to really update, drop --dry-run (the pull itself is the "is there a new version" decision)
```

To rehearse on a Compose project, either look at the image list like this first, or run a real round on a test project.

> **A failed scheduled task now shows the reason directly**: the failure reason is written to stderr on top of being part of the complete log.
> A scheduled task keeps only stderr when the task fails; earlier versions wrote to stdout only, so the task was left with nothing but `exit status 1` and nothing to debug with.

## Rollback

The rollback point differs between container mode and Compose mode, and the difference matters.

**Container mode**: the rollback point is the **backup container** DPanel creates, named like `<container-name>-bak-<timestamp>` (for example `myapp-bak-20261103163808`).
It runs the image from before the upgrade and is in the `Exited` state; it is visible right in the DPanel web UI. Rolling back from the command line:

```sh
docker stop <container-name> && docker rm <container-name>
docker rename <container-name>-bak-<timestamp> <container-name>
docker start <container-name>
```

**Compose mode**: it **does not create a backup container and does not maintain `<repo>:prev`**. What helps is that the `docker compose pull` here only pulls and never deletes old images, so the old image is still present locally; the previous round's log line `已重建：<名>（旧12位 → 新12位）` records both the old and the new image id.
The emergency fix is to re-tag the old image as `<repo>:latest` and force a rebuild:

```sh
docker tag <old-image-id> <repo>:latest
docker compose up -d --force-recreate
```

> To be safer, note down the image ID the container currently uses before the upgrade (`docker inspect -f '{{.Image}}' <container-name>`), so you do not have to dig through logs afterwards.

## Versions and upgrades

The URL uses `releases/latest/download/`, which **contains no version number and always points at the latest published release** — copy and paste it as is.

The script's own version number is visible in the log and in `--version`:

```sh
sh container-autoupdate.sh --version    # e.g. 1.2.3
```

Publishing a new release is done automatically by the repository's GitHub Actions: as soon as the `VERSION` field in the script changes to a new value and is pushed to `main`, the workflow tags the commit and publishes a Release (see [Advanced usage](docs/advanced-usage.en.md)).

To **pin a specific version** (so it does not follow the latest), replace both download URLs in the scheduled task with tag-qualified ones:

```sh
U1='https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/download/v3.0.0/container-autoupdate.sh'
U2='https://github.com/geekMus/container-autoupdate/releases/download/v3.0.0/container-autoupdate.sh'
```

Tag numbers are listed on the [Releases](https://github.com/geekMus/container-autoupdate/releases) page.

### What to check when upgrading to v3.0.0

There is **no bootstrapper (`ct-bootstrap.sh`) any more** as of v3.0.0: installation became "download the main script inside the scheduled task → verify → run", and a Release now publishes just two assets (the main script and the read-only investigation script).

- **The scheduled task has to change once**: replace the old two lines (`curl .../ct-bootstrap.sh` + `sh /tmp/ct-bootstrap.sh`) with the block from "Quick start" above. `releases/latest/download/ct-bootstrap.sh` now returns 404, so machines that were not updated fail every round.
- **Every `--ct-*` argument and `CT_*` environment variable is obsolete** (`CT_VERSION`, `CT_SOURCE`, `CT_CACHE_DIR` and six more). If one is still in the task, the script stops immediately (exit code `3`) and prints the migration path.
- **Pinning**: use a tag-qualified download URL; `--ct-version` is gone.
- The old cache under `/var/cache/container-autoupdate` is never read again and can be deleted.

### What to check when upgrading to v2.x

Starting with v2.0.0 the script no longer implements "pull the image / rebuild the container" itself: the update action is carried out by DPanel (container mode) and by Docker's own Compose command (Compose mode) instead, and the script no longer maintains a `:prev` rollback point, a state directory or bad-version pinning. If you are upgrading from an earlier version, read the following first.

**Three arguments are obsolete** (passing one aborts immediately with exit code `3` and a migration note in the log):

- `--state-dir`: the script keeps no state directory any more; the cross-version record moved to `COMPAT_ROOT` (default `/tmp/.container-autoupdate/compat`).
- `--bad-ttl-days`: bad-version pinning is gone; rollback is DPanel's job.
- `--pull-retries`: pulling in container mode is done by DPanel and in Compose mode by `docker compose pull`; the script no longer manages pulls or retries.

> `--compose-dir` is **not on the obsolete list**: it is available again as of v2.1.0, as a fallback for the project directory.

**A batch of environment variables is obsolete the same way** (setting one aborts the run): `STATE_ROOT`, `BAD_TTL_DAYS`, `PULL_RETRIES`, `DIGEST_RETRIES`, `DIGEST_RETRY_WAIT`, `T_STALL`, `T_STALL_FINISH`, `T_PULL_MAX`, `T_UP`, `T_HEALTH`, `HEALTH_TRIES`, `T_ROLLBACK`, `PLAIN_BOOT`, `COMPOSE_BASE`, `LOCK_PREFIX` (see [All parameters and environment variables](docs/parameters.en.md) for the complete list). Just delete them; no replacement setting is needed.

> Two exceptions: `T_INSPECT` is the old name of `DP_T_CHECK` and is **still accepted**; `COMPOSE_DIR` is available again as of v2.1.0 and is equivalent to `--compose-dir`.

Other things to note:

- **`LOCK_PREFIX` is treated as a breaking change**: the script no longer takes a mutex lock internally (concurrency is guaranteed by the DPanel scheduled task), so a `LOCK_PREFIX=...` left in your start command aborts immediately (exit code `3`) and tells you so. Remove it.
- **Compose mode no longer needs DPanel registration**; it needs `docker` and the Compose v2 plugin instead. The project directory is looked up from the container labels by default, with `--compose-dir` as the fallback.
- The main script no longer needs `curl` or `flock`; pull controls such as `--pull-retries` are all obsolete — container-mode pulling is DPanel's job, Compose-mode pulling is `docker compose pull`'s job.

### Investigating leftover processes and old lock files

If an old version keeps printing `SKIP 同一更新目标（xxx）的另一个任务仍在执行`, it means a process from a previous round that did not exit cleanly is still holding the lock.
The repository ships a **read-only** investigation script: it only lists the problems (old lock files, processes holding the locks, leftover pull processes, leftover transaction directories),
changes nothing and kills nothing, and ends with copy-pasteable cleanup commands for you to run after confirming.

```sh
curl -fsSL -L https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh \
  -o /tmp/ct-stale-lock-check.sh
sh /tmp/ct-stale-lock-check.sh
```

> Starting with v2.0.0 the script **no longer creates lock files and no longer creates `/tmp/.container-autoupdate/compose-*` transaction directories** (old rollback tags such as `:prev` are no longer produced either). This script is still useful: historical residue left over from before the upgrade looks exactly the same, so use it to investigate and clean that up.
>
> Run it **in the environment that runs the updates** (with DPanel that means inside the dpanel container), because it inspects that machine's `/proc`:
> `docker exec -it dpanel sh /tmp/ct-stale-lock-check.sh`.
>
> See [Advanced usage](docs/advanced-usage.en.md#6-investigating-leftovers-from-before-the-upgrade) for the full cleanup walkthrough.

### Using latest is also safe

A new upstream release lands on your machine directly. If the new version breaks your invocation (for example a flag was renamed or removed), the script does not silently ignore it — it **stops immediately**, exits with code `3`, and writes three things into the log: which spelling no longer works, what it became starting from which version, and how to fix it.

```text
[2026-11-01 03:47:12] ERR 这个参数已经不能用了：--oldflag
[2026-11-01 03:47:12]     从 v1.0.0 起改为：--newflag
[2026-11-01 03:47:12]     原因：……
[2026-11-01 03:47:12]     迁移方式：把 --oldflag 换成 --newflag
[2026-11-01 03:47:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-01 03:47:12]     本次未做任何改动，退出码 3

→ ERR: this argument can no longer be used: --oldflag
→     starting from v1.0.0 it became: --newflag
→     reason: ...
→     migration path: replace --oldflag with --newflag
→     or pin the download URL to the old version (see "Versions and upgrades" in the README)
→     nothing was changed this round, exit code 3
```

For changes that **cannot be detected automatically** (for example a default behaviour change), the script has two fallbacks:

- **Cross-version notice**: it remembers the version each target last ran with. When you upgrade to a release that contains a breaking change, the log gets an extra `WARN` section explaining what changed and how to deal with it, and then execution continues normally.
- **`--compat <version>`**: you can declare "I have only verified up to this version". If the script is newer than that and there is a breaking change in between, it stops hard instead of taking the risk.

```sh
container-autoupdate.sh --compose myapp --compat 1.2.3
```

## More documentation

- [All parameters and environment variables](docs/parameters.en.md) — what each parameter does and when you need it
- [Advanced usage](docs/advanced-usage.en.md) — the pitfalls of downloading the script, exit codes, DPanel notes
- [How it works and safety boundaries](docs/how-it-works.en.md) — how it updates, what it skips, what it cannot protect

## License

MIT
