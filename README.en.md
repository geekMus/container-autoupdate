# container-autoupdate

> Language: [English](README.en.md) | [中文](README.md)

A single-file container auto-update script for **DPanel scheduled tasks**.

One run = one check: the script does exactly three things — decide whether an update is due, hand the update action to DPanel, and report the result faithfully. It does not pull images or rebuild containers itself. **The script contains no scheduler** — the frequency, the start/stop control and the concurrency are all delegated to DPanel's "scheduled task".

> Starting with v2.0.0, every update action is left to DPanel itself. The reason is simple: rebuilding a container means reproducing its network, mounts (including the real names of anonymous volumes), resource limits, restart policy, capabilities and much more, and missing one of them is a production incident; DPanel already does all of that properly, and the backup container it leaves behind doubles as a ready-made rollback point. The script therefore shrank from 1700-odd lines to around 700, with a small, controllable surface.

> Running it by hand is allowed too; that is a one-off run that ends when it is done. It is **not recommended** to wrap it in another timer such as cron or a systemd timer — concurrency is guaranteed by the DPanel scheduled task, one scheduled task per target.

## Two modes

| How your container was started | Which argument to use | What the script actually runs |
|---|---|---|
| `docker compose up -d` | `--compose <project-name>` | `dpanel compose:deploy --name <project-name> --pull-image dpanel` |
| `docker run ...` | `--container <container-name>` | `dpanel container:upgrade --name <container-name>` (it checks first and adds `--upgrade` only when an upgrade is needed) |

The script reads neither the Compose file nor the image reference: in both modes it just hands the target to DPanel by name.

> Pulling from the registry is entirely delegated to DPanel / the Docker daemon, using **the registry mirrors that you and the daemon configured**; the script never touches a registry at all — so "racing several mirror prefixes in parallel" is no longer needed under v2.0.0.

## Prerequisites

- **DPanel** must be installed on the target machine: every update action relies on DPanel's own command line (the `container:upgrade` / `compose:deploy` that ship with DPanel 1.11.x).
- **Running inside the dpanel container is recommended**: DPanel's "scheduled task" executes inside the dpanel container by default, and the script calls `/app/server/dpanel` directly.
- Running on the host also works, but the host needs the `docker` command: the script then calls into the container with `docker exec dpanel /app/server/dpanel ...`. When the DPanel container is not called `dpanel`, name it with `--dpanel-container <name>`.
- **The Compose project must already be registered in the DPanel web UI** (DPanel web UI → Compose → create / import). When it is not registered, DPanel returns an error, the script recognises it and prints a migration path, exit code `1`.
- Required commands: `timeout` `sed` `awk` `grep` (busybox or coreutils both work). Outside the dpanel container, `docker` is needed as well. The main script **no longer needs `curl` or `flock`** (the bootstrapper still needs `curl` to download the script).

## Quick start

### DPanel scheduled task

Create a scheduled task and paste **two lines** into the script box:

```sh
# The bootstrapper caches the script itself: the first run downloads it,
# later runs reuse the cached copy of the same version without going online
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

For a plain container, replace the last part with `--container mycontainer`.

> The `https://github.mus.pp.ua/` prefix in the download URL is a self-hosted acceleration prefix; drop it to connect to GitHub directly. If that prefix is down, use `https://gh-proxy.com/` instead — the bootstrapper itself tries the sources in the order "self-hosted → gh-proxy → direct".
>
> Set the execution timeout to **≥ 600 seconds** (the script's own hard limit is 540 seconds).
>
> **Why `curl ... | sh` is not recommended**: with a pipe, a failed download **silently succeeds** (the task log gives no hint that the round did not run). The bootstrapper writes the download to a file, verifies it, and only then executes it; on failure it returns a non-zero exit code explicitly.
>
> **Pinning a version is recommended in production**: give the bootstrapper `--ct-version <version>` (or set `CT_VERSION`; version numbers are listed on the [Releases](https://github.com/geekMus/container-autoupdate/releases) page). It then stops probing the remote and never goes online to fetch a new version. Using `latest` is fine too — when a breaking change actually breaks your invocation, the script stops by itself and writes the reason and the fix into the log.

### Run one round manually

To check once in a while, just run it (it ends when it is done, nothing stays resident). The bootstrapper has to be written to disk once:

```sh
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

> It is not recommended to schedule this with cron or a systemd timer: two rounds for the same target running at the same time will step on each other. If you want scheduled updates, use a DPanel scheduled task — one scheduled task per target is enough.

## How the bootstrapper works

| Mode | Behaviour | Network cost |
|---|---|---|
| Pinned version (`--ct-version <version>` / `CT_VERSION`) | Runs the local copy if present | **Zero** (never goes online) |
| `latest` (default), local copy is current | Only probes the remote version number, does not download | One Range request (fetches the head of the file, 16KB; about 1 second) |
| `latest`, remote has a new version | Downloads the new version, caches it, then executes it | One probe + one full download (about 80KB) |
| Probe failed but a local cache exists | Runs from the cache and prints a `WARN` | Zero |
| Probe failed and no cache exists | **Fails loudly** (never a silent success) | Zero |

The cache lives in `/var/cache/container-autoupdate` (change it with `--ct-cache-dir` / `CT_CACHE_DIR`), one file per version, keeping only the 3 most recent (`--ct-cache-keep` / `CT_CACHE_KEEP`). Cached files are checked for syntax, version number and signature string, so a half-downloaded file is never executed as a script. The bootstrapper's own switches always use the `--ct-*` prefix (the same `CT_*` environment variables also work; the command line wins); everything else is passed through to the main script unchanged.


## Common commands

```sh
container-autoupdate.sh --container mycontainer --dry-run   # container mode: ask DPanel whether a new version exists, change nothing
container-autoupdate.sh --container mycontainer             # upgrade a plain container
container-autoupdate.sh --compose myapp                     # deploy a Compose project (must be registered in DPanel)
container-autoupdate.sh --dpanel-container mydpanel --compose myapp   # when the DPanel container is not called dpanel
```

**`--dry-run` behaves differently in the two modes:**

- **Container mode**: it really asks DPanel whether a new version exists, but does not perform the upgrade. With a new version it prints a "new version found" line, without one it prints "already up to date":

```text
[2026-11-03 06:00:12] 发现新版本（远端 digest=sha256:a5c10db1...）
[2026-11-03 06:00:12] DRY 只检查不动手，本轮不升级

→ a new version was found (remote digest=sha256:a5c10db1...)
→ DRY: check only, hands off; no upgrade this round
```

- **Compose mode**: DPanel's `compose:deploy` is a deploy action in itself and has no "check only" ability. The script prints one explanatory line, exits `0` and **does nothing at all** (it does not tell you whether a new version exists either):

```text
[2026-11-03 06:00:12] DRY Compose 模式没有「只检查」能力（DPanel 的 compose:deploy 会直接部署）
[2026-11-03 06:00:12]     本轮未执行部署；要检查容器有没有新版本请用 --container 模式

→ DRY: Compose mode has no "check only" ability (DPanel's compose:deploy deploys directly)
→     no deployment was performed this round; to check whether a container has a new version, use --container mode
```

To rehearse on a Compose project, either deploy for real on a test project, or switch to container mode for the check.

> **A failed scheduled task now shows the reason directly**: the failure reason is written to stderr on top of being part of the complete log.
> A scheduled task keeps only stderr when the task fails; earlier versions wrote to stdout only, so the task was left with nothing but `exit status 1` and nothing to debug with.

## Rollback

The rollback point differs between container mode and Compose mode, and the difference matters.

**Container mode**: the rollback point is the **backup container** DPanel creates, named like `<container-name>-bak-<timestamp>` (for example `myapp-bak-20261103163808`).
It runs the image from before the upgrade and is in the `Exited` state; it is visible right in the DPanel web UI, and rolling back means putting it back.

**Compose mode**: it **does not create a backup container and does not maintain `:prev`** — DPanel's compose deployment has no backup mechanism.
Rolling back relies on the old image still being present locally:

```sh
docker tag <old-image-id> <repo>:latest
docker compose up -d --force-recreate
```

> Note down the image ID the container is currently using before the upgrade (`docker inspect -f '{{.Image}}' <container-name>`), otherwise you may not find that old image afterwards.

## Versions and upgrades

The URL uses `releases/latest/download/`, which **contains no version number and always points at the latest published release** — copy and paste it as is.

The script's own version number is visible in the log and in `--version`:

```sh
sh container-autoupdate.sh --version    # e.g. 1.2.3
```

Publishing a new release is done automatically by the repository's GitHub Actions: as soon as the `VERSION` field in the script changes to a new value and is pushed to `main`, the workflow tags the commit and publishes a Release (see [Advanced usage](docs/advanced-usage.en.md)).

To **pin a specific version** (so it does not follow the latest), give the bootstrapper `--ct-version`:

```sh
/usr/local/bin/ct-bootstrap.sh --ct-version 1.2.3 --compose myapp
# The old spelling still works: CT_VERSION=1.2.3 /usr/local/bin/ct-bootstrap.sh --compose myapp
```

A pinned bootstrapper never goes online at all, which is the most stable shape for production. Tag numbers are listed on the [Releases](https://github.com/geekMus/container-autoupdate/releases) page.

### What to check when upgrading to v2.0.0

v2.0.0 hands the whole update action to DPanel: **the script no longer pulls images itself and no longer rebuilds containers itself**, and it no longer maintains a `:prev` rollback point, a state directory or bad-version pinning. If you are upgrading from an earlier version, read the following first.

**Four arguments are obsolete** (passing one aborts immediately with exit code `3` and a migration note in the log):

- `--compose-dir`: Compose updates are handled by DPanel by project name; the project directory is no longer needed.
- `--state-dir`: the script keeps no state directory any more; the cross-version record moved to `COMPAT_ROOT` (default `/tmp/.container-autoupdate/compat`).
- `--bad-ttl-days`: bad-version pinning is gone; rollback is DPanel's job.
- `--pull-retries`: pulling is done by DPanel; the script no longer manages pulls or retries.

**A batch of environment variables is obsolete the same way** (setting one aborts the run). The main ones: `STATE_ROOT`, `BAD_TTL_DAYS`, `PULL_RETRIES`, `DIGEST_RETRIES`, `DIGEST_RETRY_WAIT`, `T_STALL`, `T_STALL_FINISH`, `T_PULL_MAX`, `T_UP`, `T_HEALTH`, `HEALTH_TRIES`, `T_ROLLBACK`, `PLAIN_BOOT`, `COMPOSE_DIR`, `COMPOSE_BASE` (see [All parameters and environment variables](docs/parameters.en.md) for the complete list). Just delete them; no replacement setting is needed.

> One exception: `T_INSPECT` is still accepted, and is equivalent to the new `DP_T_CHECK`.

Other things to note:

- **The old `LOCK_PREFIX` still trips the abort**: the script no longer takes a mutex lock internally (concurrency is guaranteed by the DPanel scheduled task), so a `LOCK_PREFIX=...` left in your start command is treated as a breaking change, aborts immediately (exit code `3`) and tells you so. Remove it.
- **The Compose project must already be registered in the DPanel web UI**, otherwise the round fails and exits (exit code `1`) instead of updating.
- The main script no longer needs `curl` or `flock`; pull controls such as `--pull-retries` are all obsolete — pulling is DPanel's job.

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
