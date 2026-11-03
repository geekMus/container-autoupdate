# container-autoupdate

> Language: [English](README.en.md) | [中文](README.md)

A single-file container auto-update script for **DPanel scheduled tasks**.

One run = one check: if a new version exists it updates and verifies it, otherwise it exits immediately. **The script contains no scheduler** — the frequency, the start/stop control and the concurrency are all delegated to DPanel's "scheduled task".

> Running it by hand is allowed too; that is a one-off run that ends when it is done. It is **not recommended** to wrap it in another timer such as cron or a systemd timer — the script no longer takes a mutex lock internally, so two rounds for the same target running at the same time will step on each other.

## Two modes

| How your container was started | Which argument to use |
|---|---|
| `docker compose up -d` | `--compose <project-name>` |
| `docker run ...` | `--container <container-name>` |

You do not fill in the image reference: the script reads it from the Compose file or from the container itself.

## Quick start

### DPanel scheduled task

Create a scheduled task and paste **two lines** into the script box:

```sh
# The bootstrapper caches the script itself: the first run downloads it,
# later runs reuse the cached copy of the same version without going online
curl -fsSL https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

For a plain container, replace the last part with `--container mycontainer`.

> Set the execution timeout to **≥ 600 seconds**.
>
> **Why `curl ... | sh` is not recommended**: with a pipe, a failed download **silently succeeds** (the task log gives no hint that the round did not run). The bootstrapper writes the download to a file, verifies it, and only then executes it; on failure it returns a non-zero exit code explicitly.
>
> **Pinning a version is recommended in production**: give the bootstrapper `--ct-version <version>` (or set `CT_VERSION`; version numbers are listed on the [Releases](https://github.com/geekMus/container-autoupdate/releases) page). It then stops probing the remote and never goes online to fetch a new version. Using `latest` is fine too — when a breaking change actually breaks your invocation, the script stops by itself and writes the reason and the fix into the log.

### Run one round manually

To check once in a while, just run it (it ends when it is done, nothing stays resident). The bootstrapper has to be written to disk once:

```sh
curl -fsSL https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

> It is not recommended to schedule this with cron or a systemd timer: the script no longer takes a mutex lock internally, so two rounds for the same target running at the same time will step on each other. If you want scheduled updates, use a DPanel scheduled task — one scheduled task per target is enough.

## How the bootstrapper works

| Mode | Behaviour | Network cost |
|---|---|---|
| Pinned version (`--ct-version <version>` / `CT_VERSION`) | Runs the local copy if present | **Zero** (never goes online) |
| `latest` (default), local copy is current | Only probes the remote version number, does not download | One 4KB Range request (about 1 second) |
| `latest`, remote has a new version | Downloads the new version, caches it, then executes it | One probe + one full download (about 70KB) |
| Probe failed but a local cache exists | Runs from the cache and prints a `WARN` | Zero |
| Probe failed and no cache exists | **Fails loudly** (never a silent success) | Zero |

The cache lives in `/var/cache/container-autoupdate` (change it with `--ct-cache-dir` / `CT_CACHE_DIR`), one file per version, keeping only the 3 most recent (`--ct-cache-keep` / `CT_CACHE_KEEP`). Cached files are checked for syntax, version number and signature string, so a half-downloaded file is never executed as a script. The bootstrapper's own switches always use the `--ct-*` prefix (the same `CT_*` environment variables also work; the command line wins); everything else is passed through to the main script unchanged.


## Common commands

```sh
container-autoupdate.sh --compose myapp --dry-run    # only check whether a new version exists; no update, no image removal
container-autoupdate.sh --compose myapp              # update the Compose project for real
container-autoupdate.sh --container mycontainer      # update a plain container
container-autoupdate.sh --compose myapp --pull-retries 2   # retry one more time when the pull fails (default: 1)
```

**When you first set it up, run `--dry-run` first** and confirm that the target and the directories it recognises in the log are right, then drop it.
(A dry run only writes the state directory; it does not touch containers, does not touch image tags and does not clean up old images.)

A failed pull (network hiccup, transient 5xx from the registry) is **retried once** by default, with 10 seconds between the two attempts;
`--pull-retries <count>` changes the number of retries, `0` = do not retry.
A **stalled pull** (no new bytes for 60 seconds) and an **explicit error from the registry** (image does not exist, authentication failed) are *not* retried — retrying would not succeed either.

Querying the remote digest (asking the registry "what is the latest digest") is likewise **retried twice** by default, 5 seconds apart;
`DIGEST_RETRIES` / `DIGEST_RETRY_WAIT` are tunable, `DIGEST_RETRIES=0` = do not retry.

> **A failed scheduled task now shows the reason directly**: the failure reason is written to stderr on top of being part of the complete log.
> A scheduled task keeps only stderr when the task fails; earlier versions wrote to stdout only, so the task was left with nothing but `exit status 1` and nothing to debug with.

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

### What to check when upgrading to a version without the mutex lock

Newer versions have **removed the mutex lock inside the script** (and the `LOCK_PREFIX` environment variable is obsolete with it) —
concurrency is now guaranteed by the DPanel scheduled task.

How to tell whether you ever hit this problem: if your old logs keep repeating

```text
[2026-11-02 19:00:05] SKIP 同一更新目标（compose-myapp）的另一个任务仍在执行，本轮跳过

→ SKIP: another task for the same update target (compose-myapp) is still running; skipping this round
```

and **every round looks identical and nothing is ever updated** — that means the old version's lock was held for a long time by a child process that did not exit cleanly.
After the upgrade the symptom disappears on its own.

After upgrading, confirm two things:

1. **Only one DPanel scheduled task per target** (the script no longer shields you from concurrency).
2. If `LOCK_PREFIX=...` is still left in your start command, remove it. If it stays, the script treats it as a breaking change,
   aborts immediately and tells you so (exit code `3`) instead of silently ignoring it.

### Investigating leftover processes and old lock files

If an old version keeps printing `SKIP 同一更新目标（xxx）的另一个任务仍在执行`, it means a process from a previous round that did not exit cleanly is still holding the lock.
The repository ships a **read-only** investigation script: it only lists the problems (old lock files, processes holding the locks, leftover pull processes, leftover transaction directories),
changes nothing and kills nothing, and ends with copy-pasteable cleanup commands for you to run after confirming.

```sh
curl -fsSL -L https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh \
  -o /tmp/ct-stale-lock-check.sh
sh /tmp/ct-stale-lock-check.sh
```

> Run it **in the environment that runs the updates** (with DPanel that means inside the dpanel container), because it inspects that machine's `/proc`:
> `docker exec -it dpanel sh /tmp/ct-stale-lock-check.sh`.
>
> See [Advanced usage](docs/advanced-usage.en.md#7-investigating-leftover-processes-and-old-lock-files) for the full cleanup walkthrough.

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
