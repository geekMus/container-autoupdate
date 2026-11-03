# Advanced usage

> Language: [English](advanced-usage.en.md) | [中文](advanced-usage.md)

> For the basic usage see the [README](../README.en.md). What is covered here is **how to download the script, exit codes, scheduled task details, and a few easy traps**.
>
> The script is meant for a **DPanel scheduled task**: one run ends by itself, the frequency and the concurrency are delegated to DPanel.
> One scheduled task per target is enough (the script takes no mutex lock internally). Running it by hand is a one-off run,
> and it is not recommended to wrap it in another cron / systemd timer.

## 1. Getting the script onto a machine

**The bootstrapper is recommended in production** (`ct-bootstrap.sh`): it takes care of downloading and caching, and you only maintain one command line.

### Recommended: use the bootstrapper (it has a cache, so it does not have to go online every round)

```sh
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /usr/local/bin/ct-bootstrap.sh
chmod +x /usr/local/bin/ct-bootstrap.sh
/usr/local/bin/ct-bootstrap.sh --compose myapp
```

What the bootstrapper does on each run:

| Situation | Network cost |
|---|---|
| Pinned with `--ct-version <version>` (or `CT_VERSION`) and the local copy exists | **Zero** (never goes online) |
| Default (follows latest), the local copy is the same version | One Range probe (fetches the head of the file, 16KB; about 1 second), no download |
| Default, the remote has a new version | Probe + one full download, then cached |
| Probe failed but a local cache exists | Zero (uses the cache, prints `WARN`) |
| Probe failed and there is no cache | Zero, but **fails loudly** (never a silent success) |

There are three benefits: a failed download returns a non-zero code explicitly; a cache hit needs no network (mirror flakiness does not stop the script from starting); the cached file is checked for syntax + version number + signature string, so a half-downloaded file is never executed as a script.

See the [parameter reference](parameters.en.md#bootstrapper-ct-bootstrapsh-parameters-and-environment-variables) for all configuration options.

### Alternative: download the main script to a file and execute it (no cache)

If you do not want to use the bootstrapper, run the main script directly. Note that in this case **the script does not upgrade itself** — you have to download it again yourself from time to time:

```sh
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh \
  -o /usr/local/bin/container-autoupdate.sh
chmod +x /usr/local/bin/container-autoupdate.sh
/usr/local/bin/container-autoupdate.sh --compose myapp
```

### For verification only: write to a temporary file and execute it (leaves nothing on disk)

Use this when you want to check the network and the arguments quickly, without leaving a file behind:

```sh
URL=https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
_t=$(mktemp)
if curl -fsSL --max-time 60 "$URL" -o "$_t"; then
  sh "$_t" --compose myapp
else
  echo "下载失败" >&2; rm -f "$_t"; exit 1
fi
rm -f "$_t"
    → the failure message printed to stderr is Chinese ("download failed")
```

When the download fails, `exit 1` shows up in the task log instead of being silently treated as success. **But it downloads on every round**, so it is not recommended for production.

### Not recommended: execute straight through a pipe

```sh
curl -fsSL "$URL" | sh -s -- --compose myapp
```

It runs, but there are three limitations you have to know:

1. **A failed download is swallowed.** When `curl -f` fails the pipeline still counts as a "success" (`sh` gets empty input, executes nothing, exit code 0). The scheduled task sees "this round finished normally" while in fact nothing happened.
2. **It goes online to download on every round** — mirror flakiness (403/522/`Recv failure`) is enough to make that round fail to start.
3. **Do not put a fallback inside the pipe.** The `curl A || curl B | sh` form has two traps:
   - When A succeeds its output is **discarded**; what actually runs is `curl B | sh` — you think you are running A's version, but B is the one that runs;
   - When both fail, `sh` gets empty input and silently succeeds with exit code 0.

   To add a fallback, put them in parentheses: `( curl A || curl B ) | sh`, or simply write to a temporary file (see above).

> To make the pipe form surface failures too, wrap it in `set -o pipefail` in your own outer layer (busybox sh supports it as well):
> ```sh
> set -o pipefail
> curl -fsSL "$URL" | sh -s -- --compose myapp
> ```
> This way the whole command returns non-zero when `curl` fails.
>
> **But it has one side effect**: if the script exits before it has read the whole input (the fast-exit cases such as `--version`, `--help` or an argument error), `curl` gets `curl: (23) Failure writing output to destination`, and the whole pipeline then returns `23` — even though the script itself succeeded. Measured: `--version` with pipefail returns `23`, while `--compose ... --dry-run` returns `0` when it runs to the end.
>
> So **pipefail is only suitable for fixed arguments and for scenarios that run the whole flow to the end** (for example `--compose myapp` hard-coded in a DPanel scheduled task). When you want to use `--version`/`--help`, or when the arguments may be wrong, use the temporary file form above instead.

## 2. Versions: follow the latest release by default, or pin one

**Default usage**: the bootstrapper's URL uses `releases/latest/download/ct-bootstrap.sh`, and on every run it decides by itself whether the main script has to be updated.

It is not the same as `/main/`: `/main/` points at the newest commit of the branch, including intermediate states that have not been released (including commits that only touch the documentation); `releases/latest/` points only at a version that **has passed the checks and been officially released**.

**To pin a version**: give the bootstrapper `--ct-version` (you do not have to change the download URL; the environment variable `CT_VERSION` works as well):

```sh
/usr/local/bin/ct-bootstrap.sh --ct-version 1.2.3 --compose myapp
```

Once pinned, the bootstrapper **never goes online to fetch a new version** — if the local copy has that version it runs it directly. This is the most stable shape for production.

If you do not use the bootstrapper and run the main script directly, replace `latest/download` in the URL with a concrete tag (the tag numbers are listed on the [Releases](https://github.com/geekMus/container-autoupdate/releases) page):

```sh
https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/download/v1.2.3/container-autoupdate.sh  # 示例占位：把 v1.2.3 换成 Releases 页面上的真实 tag
    → the trailing comment is Chinese ("example placeholder: replace v1.2.3 with the real tag from the Releases page")
```

When you should pin: when you do not want the behaviour to change suddenly on an unattended production machine. Once pinned, an upgrade becomes an explicit version-number replacement.

To see which version is currently in use:

```sh
sh container-autoupdate.sh --version
```

> **Release mechanism**: the `VERSION` field in the repository (the `VERSION` field at the top of the script, of the form `VERSION="1.2.3"`) is the single source of the version. When it is pushed to `main`, GitHub Actions reads it; if the corresponding tag does not exist yet, it creates the tag and publishes the Release automatically, uploading the script as a Release asset. So an upgrade only means changing one place, `VERSION`; neither the README nor the download URLs have to change.

> Note: **do not use the `refs/tags/<tag>` form**. Some mirror services (including the self-hosted one) time out on it. Use `/releases/download/<tag>/` or a short tag path.

### How breaking changes show up when you follow latest

This explains the mechanism behind "following latest is safe too". When upstream breaks your invocation, the script handles it in three categories:

| Change type | Example | What the script does |
|---|---|---|
| An argument was removed or renamed | `--target` split into `--compose` / `--container` | **Aborts immediately** with exit code `3`; the log states which argument no longer works, what it became starting from which version, and how to change it |
| An environment variable was removed or renamed | `UPD_TARGET` split into `UPD_COMPOSE` / `UPD_CONTAINER` | Same as above |
| A default behaviour or the semantics changed | The number of rollback copies changes from 1 to 2 by default | Cannot be judged from the input; the two mechanisms below cover it |

The last category is covered by these two mechanisms:

**① Cross-version notice.** The script remembers under `--state-dir` the version each target last ran with (`compat/compose-<名>/lastver`, `compat/plain-<名>/lastver`). When this run's version is higher and there is a breaking change in between, the log gets an extra section at the beginning:

```sh
[2026-11-01 03:52:03] WARN 你从 1.0.0 之前的版本(0.9.0)升级上来，v1.0.0 引入了破坏性变更
[2026-11-01 03:52:03]      变更：默认保留 2 份回滚副本
[2026-11-01 03:52:03]      应对：如只想保留 1 份，加 --keep 1
[2026-11-01 03:52:03]      本次仍会继续执行。两条路选一条：
[2026-11-01 03:52:03]        1) 接受上面的新做法（想让下一次破坏性变更前先停住，可加 --compat 1.0.0）
[2026-11-01 03:52:03]        2) 想继续用旧行为，把下载地址固定到 v0.9.0 那个 tag
    → WARN: you are upgrading from a version before 1.0.0 (0.9.0); v1.0.0 introduced a breaking change
    →     change: 2 rollback copies are kept by default
    →     how to deal with it: if you only want to keep 1 copy, add --keep 1
    →     this run will still continue. Pick one of the two paths:
    →       1) accept the new behaviour above (to stop before the next breaking change, add --compat 1.0.0)
    →       2) keep the old behaviour and pin the download URL to the v0.9.0 tag
```

It does **not abort** (because it cannot know whether you depend on the old behaviour), it only notifies. The same version does not trigger a repeated notice, and a downgrade does not trigger one either.

> Note: do not follow the notice by adding `--compat 0.9.0`: that value makes the `--compat` mechanism described below **stop hard** (exit code `3`),
> which means it stops on every single run. To "stop before the breaking change" you should write `--compat 1.0.0` (= the current script version).

**② `--compat <version>`.** You can declare "I have only verified up to this version". If the script is newer and there is a breaking change in between, it stops hard (exit code `3`) instead of taking the risk:

```sh
container-autoupdate.sh --compose myapp --compat 0.9.0
```

Suitable when: you have verified `0.9.0` in production, but one day `latest` jumps to `1.0.0` and you have not had time to run a regression — adding `--compat 0.9.0` amounts to "as soon as you hit a breaking change I have not verified, do not touch my container". Once you have finished verifying, change the number to the new version or remove it altogether.

Boundary behaviour of `--compat`:

- An invalid value (for example `abc`) → exit code `3`
- A value newer than the script (for example the script is `1.0.0` but you wrote `--compat 1.5.0`, which usually means the download URL is wrong) → exit code `3`
- A value equal to or higher than the version with the change → let it pass
- No breaking change is registered at all → let it pass without bothering you

> Maintainer view: breaking changes are registered in the script's `BREAKING_TABLE`. New capabilities, changes to the log wording and changes to the internal implementation must **not** be registered, otherwise every release bothers the user.

## 3. Mainland China network: switch to a mirror prefix

`raw.githubusercontent.com` often cannot be reached from mainland China (measured: repeated 8-second timeouts). The bootstrapper's default source already handles this (`CT_SOURCE=auto` tries **self-hosted mirror → gh-proxy → direct → ghproxy.net** in turn, and moves on to the next source whenever one fails).

Default source order (measured 2026-11-03 inside the N1 dpanel container):

| Order | Prefix | Measured |
|---|---|---|
| 1 | `https://github.mus.pp.ua/` | Self-hosted. Both the Range probe and the full download correctly forward Release assets (sha256 matches the official one); but it times out occasionally — 3 out of 5 attempts succeeded |
| 2 | `https://gh-proxy.com/` | Public. 5 out of 5 succeeded, about 1 second on average — the most stable |
| 3 | `https://github.com/` (no prefix) | A direct download of a Release asset is more stable than a raw file, but it does show occasional DNS failures (`curl: (6)`) and 12-second delays |
| 4 | `https://ghproxy.net/` | Public (measured: repeated 15-second timeouts; only used as the last fallback) |

The full form when you write the URL by hand:

```sh
# Self-hosted mirror (the default first choice)
https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh

# Public acceleration mirror (the default fallback)
https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh
```

To make the bootstrapper use one specific source only: `CT_SOURCE=mus` (self-hosted), `CT_SOURCE=gh-proxy`, `CT_SOURCE=direct`, `CT_SOURCE=ghproxy`, or pass any custom prefix directly.

> **Always pass `-L`** (or `--location`). `releases/latest/download/` first answers with a 302 redirect to the URL of the concrete tag; without `-L`, `curl -f` treats it as a failure (`curl: (22)`).
>
> Mirror prefixes **occasionally** return `403` / `522` / timeouts for Release assets (measured: the same URL failed a few minutes ago and returned 200 a few minutes later). That is flakiness on the mirror side, not a wrong URL — a retry usually works. The bootstrapper tries each source twice by default (`CT_TRIES`) and falls back to the local cache when the probe fails.
>
> Do **not** use `cdn.jsdelivr.net` for this repository: in practice it returns a cached old version (`@main` once served historical content with `VERSION=6.0.0`). jsdelivr suits static files at a fixed tag, not the "follow the latest release" scenario.

### How many bytes the version probe fetches

To keep the traffic small, the bootstrapper fetches only the head of the file (a `Range` request) when it looks for the version number. The size of that window is `--ct-probe-bytes` / `CT_PROBE_BYTES` (16KB by default).

> **The pitfall hit here**: the window used to be fixed at 4KB, but the `VERSION=` line moves further down as the header comments of the script grow (one release had already pushed it to byte 4012). As soon as the window no longer covers it, the probe fails silently — the log only shows `WARN 探测远端版本失败（网络问题）` while the network was perfectly fine.
>
> The window is now 16KB, and **when the version number is not found, the whole file is fetched once and parsed again**. So as long as the network works, the probe no longer fails because the version line moved down.
>
> When you see "probe failed", look at the `探测远端版本：<URL>` line right above it — it tells you which source and which address was being tried.

## 4. Exit codes

| Exit code | Meaning | What to do |
|---|---|---|
| `0` | Successful update / nothing to update / safely skipped by the rules | Nothing to do |
| `1` | A configuration or environment error, or the update did not finish this round (**the container is left as it was**) | Look at the `ERR` in the log; the container was not modified, so there is nothing to rescue |
| `2` | **The rollback itself failed**, manual intervention is needed | Look at the `CRITICAL` in the log right away; the scene is preserved in `--state-dir` (default `/tmp/.container-autoupdate`) |
| `3` | **A breaking change was detected**, your invocation no longer works (nothing was changed this round) | Change the command according to the "migration path" in the log; or pin a version; or add `--compat` |

`2` is the only case where you have to step in and rescue things yourself. The script preserves the scene (the new container, the old container, the tag state), so do not rush to restart the machine or run `docker system prune`.

## 5. Scheduled task details

### DPanel scheduled task (recommended)

- You can write several lines of shell directly in the script box; `curl | sh` works there as well.
- **Set the execution timeout to ≥ 600 seconds**. The script's own hard limit is 540 seconds (`T_HARD`), so this leaves some headroom.
- When DPanel edits a task in the UI, it **drops the two fields you typed in by hand, "execution timeout" and "EntryShell"** (this is known DPanel behaviour). After changing the schedule, come back and check that the timeout is still there.
- To pass environment variables to the script, use the Environment entry of the task panel (DPanel supports it natively and merges it with the Docker environment at run time).
- Several tasks can coexist, each with a different target. **Put only one scheduled task on each target** (the script takes no mutex lock internally, so two tasks running at the same time will step on each other).

### Run one round manually

```sh
container-autoupdate.sh --compose myapp
```

It ends when it is done, which suits "let me check right now whether there is a new version".

### About cron / systemd timer

It is **not recommended** to run this script on a schedule with cron or a systemd timer: the script no longer takes a mutex lock internally, so two rounds for the same target running at the same time will step on each other. For scheduled updates, use a DPanel scheduled task.

(If you really want to use cron, make sure yourself that only one instance per target runs at any given moment, for example by staggering the times in the crontab expression.)

## 6. Managing several targets on the same machine

Different targets do not affect each other, so they can run at the same time:

```sh
container-autoupdate.sh --compose app1 &
container-autoupdate.sh --compose app2 &
wait
```

Do **not** run two rounds for the **same target** at the same time (the script no longer takes a lock to stop you), otherwise the two rounds will step on each other. Wait for the previous round to finish before starting the next one.

If you want several copies of the script to be completely independent (each with its own state directory), give them different `--state-dir` values.

## 7. Investigating leftover processes and old lock files

Older versions (the ones that used a mutex lock) sometimes keep printing:

```text
[2026-11-02 19:00:05] SKIP 同一更新目标（compose-myapp）的另一个任务仍在执行，本轮跳过

→ SKIP: another task for the same update target (compose-myapp) is still running; skipping this round
```

and **every round looks identical and nothing is ever updated**. The reason is not that some other task is really running, but that **a child process from a previous round did not exit cleanly**
and kept holding the lock on behalf of the main script (see [How it works and safety boundaries](how-it-works.en.md)).

The repository ships a **read-only** investigation script `scripts/ct-stale-lock-check.sh`: it changes nothing and kills nothing,
it only lists the following and ends with copy-pasteable cleanup commands:

1. the old lock files (current versions do not use a lock any more, they are just leftover garbage);
2. who is holding those lock files open (PID / PPID / fd / command line);
3. leftover image pull processes;
4. the leftover transaction directories in the state directory, marking which ones may be deleted and which ones must be kept.

### How to use it

```sh
curl -fsSL -L https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh \
  -o /tmp/ct-stale-lock-check.sh
sh /tmp/ct-stale-lock-check.sh
```

**Run it in the environment that runs the updates**: the script inspects that machine's `/proc`. With DPanel that means inside the container:

```sh
docker cp /tmp/ct-stale-lock-check.sh dpanel:/tmp/ct-stale-lock-check.sh
docker exec -it dpanel sh /tmp/ct-stale-lock-check.sh
```

Optional environment variables: `CT_LOCK_PREFIX` (lock file prefix, default `/tmp/.container-autoupdate`),
`CT_STATE_ROOT` (state directory, default `/tmp/.container-autoupdate`).

### After you look at the result

| What you see | May it be deleted | Notes |
|---|---|---|
| Old `.lock` files | **yes** | Current versions do not use a lock any more, they are just garbage. Deleting them affects nothing. |
| Processes holding a lock | **check first, then kill** | Look at the command line first: `cat /proc/<PID>/cmdline` (NUL separated). Only kill it once you are sure it is a leftover that did not exit cleanly. |
| Leftover pull processes (`images/create`) | **yes, kill them** | The pull should have ended long ago; a process that is still alive is a leftover. |
| The `compat/` directory | **may be left alone** | It only records "the version each target last ran with"; deleting it only means you get the notice once more on the next upgrade. |
| Transaction directories (`compose-*` / `plain-*`) | **read the logs before deleting** | They mean that round ran into trouble. The `pull.log` / `create.json` inside are the only evidence of *why* it failed. |

### The real fix

Cleaning up is only a patch. **The actual fix is to upgrade to a version that no longer uses a mutex lock** — a new version has no lock, so there is no "held by a leftover process" situation in the first place.
After upgrading, confirm two things: only one DPanel scheduled task per target, and no leftover `LOCK_PREFIX=...` in the start command
(if there is one, the script treats it as a breaking change, aborts and exits with code `3`).

## 8. Common questions

**Q: The log says `已是最新`, but upstream clearly published a new version.**
A: The message means "already up to date". The script compares the **remote digest** with **the image the container is actually running**. This happens when upstream published a release but the tag content did not change (rare), or when you use a fixed digest reference. Use `--dry-run` first to see which remote digest it recognises.

**Q: The log says `SKIP 容器 xxx 属于 Compose 项目 yyy`.**
A: The message means "SKIP container xxx belongs to Compose project yyy". That container was started by compose, so you should use `--compose yyy` and let compose do the rebuild. Rebuilding it in container mode makes compose's metadata inconsistent.

**Q: After the update the container came up but the service is not working, yet the script says it succeeded.**
A: The script can only judge "container health", it cannot judge "business correctness". When the image ships a healthcheck the health gate is fairly reliable; without a healthcheck it only watches for 30 seconds whether the container is still running (`PLAIN_BOOT`), which is blind to a service that crashes right after start-up or is half-dead. For such services it is recommended to add a healthcheck in the Compose file.

**Q: After the rollback the data is wrong.**
A: A rollback only restores the **container and the image**; it does not undo the migrations the new version has already applied to the data volume / the database. This is a design boundary, not a bug. Please make separate backups of production data.

**Q: Can one run update several targets at once?**
A: No, one process handles one target. To do it in bulk, wrap it in a loop or run things in parallel on the outside (see section 6).

**Q: Can the files in `--state-dir` be deleted?**
A: There are three cases:

- **Normal successful finish** (exit code `0`): the transaction directory is cleaned up automatically, nothing to do.
- **Rollback succeeded** (exit code `1`, the container has been restored): the scene is **kept on purpose**, because `create.json` / the old and new specs / `pull.log` are the only evidence of why this round failed, and the end of the log prints `回滚现场已保留在 …` ("the rollback scene has been preserved in …"). Delete it by hand once you are done investigating.
- **The rollback itself failed** (exit code `2`): the scene must be kept; it is all you have when taking over manually.

The pre-existing `--state-dir` directory itself is not emptied; only the per-round transaction subdirectory is.
