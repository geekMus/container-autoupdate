# How it works and safety boundaries

> Language: [English](how-it-works.en.md) | [中文](how-it-works.md)

> This page explains **how** the script works, **when it refuses to act**, and **what it cannot protect**. It is worth three minutes of reading before you use it.

## 1. What one round does

```
0. Dependency self-check → connect to Docker
1. Read the image reference from the Compose file / from the container itself
2. Ask the remote "what is the latest digest" and compare it with the image
   the container is actually running
     if it cannot be fetched, retry (twice by default, 5 seconds apart;
     DIGEST_RETRIES / DIGEST_RETRY_WAIT are tunable)
     still unavailable → abandon this round (the container stays untouched)
     same → print "already up to date" and exit (usually 2~4 seconds)
3. Tag the current image as <repo>:rollback-pending as a placeholder (does not touch :prev)
4. Pull the new version through the Docker Engine API, watching the byte counters
     no new bytes for 60 seconds → judged stalled, kill -9, abandon this round (the container stays untouched)
     but after all layers are pulled there is a separate grace period (180 seconds by
     default, T_STALL_FINISH) — that is the time Docker spends writing the image
     configuration and fetching the signature, and it does not emit a single byte then
     before giving up, the script first asks the daemon whether the image actually
     landed → if it did, the round counts as successful
     the pull fails → retried once by default (--pull-retries is tunable; 0 = no retry)
5. Verify: the digest that landed on disk must equal the digest reported by the pull stream itself
6. Switch over (see the next two sections)
7. Health gate
     success → only then is the rollback point :prev moved to the previous version, old images are cleaned up
     failure → roll back, the bad version is pinned as <repo>:bad (released automatically after 7 days)
```

**A failed pull is retried, once by default.** When the pull fails (network hiccup, transient 5xx from the registry, the pull stream dropping halfway) it is retried once, with 10 seconds between the two attempts; use `--pull-retries <count>` to change the number, `0` = no retry (equivalent to the old behaviour).

Not every failure is retried:

- **An explicit error from the registry** (the image does not exist, the repository name is wrong, authentication failed) is not retried — retrying would not succeed either, it would only waste time.
- **Not enough time budget left** means no retry — the remaining time has to be reserved for the health gate and the rollback. Better to fail this round than to let the scheduled task be killed by its execution timeout and time out again on the next round.
- **A retry has its own share of the time budget** — it must not eat into the share reserved for the images after it.

The original "never retry anything" was deliberate (back then the judgement was: stalls happen during the "connect / fetch the manifest" phase, so a retry would only burn the time budget). The two cases are now separated: a **stall** (60 seconds without bytes) is still abandoned right away, while a **failure** (the stream ended but the result is not right) is retried — the latter is usually a transient fault, and one retry normally succeeds.

**Querying the remote digest is retried too.** Asking the registry "what is the latest digest" is just as prone to transient faults, so it is retried twice by default with 5 seconds in between (`DIGEST_RETRIES` / `DIGEST_RETRY_WAIT` are tunable, `DIGEST_RETRIES=0` = no retry).
When the digest cannot be fetched the script does not guess "probably not updated" — it abandons the round and writes how many attempts it made into the log.

**The "finishing phase" of a pull has its own grace period.** After Docker has pulled every layer it still has to write the image configuration
(fetching the signature from the registry), and during that time the pull stream **does not emit a single byte**.
Judging that with "60 seconds without bytes = stalled" kills a pull that was about to succeed,
and the daemon then reports `context canceled`, so **all the layers that were already downloaded are thrown away**
(this really happened in production: every layer was `Pull complete`, only the image configuration was missing, the script cut the stream off
and the whole round was wasted). So the script does two things: once all layers are pulled it enters a separate finishing grace period
(`T_STALL_FINISH`, 180 seconds by default); and when that grace period expires without a digest it **first asks the daemon whether the image actually landed** —
if it really did (the tag points at the new image and RepoDigests has a value) the round ends as a success instead of wasting the work.

**The failure reason is written to stderr as well.** A scheduled task keeps only stderr and discards stdout when the task fails;
so the `ERR` / `CRITICAL` lines (and the indented follow-up lines right after them) are **also** written to stderr, on top of being part of the complete log.
That way the scheduled task is not left with nothing but a bare `exit status 1`. See [the parameter docs](parameters.en.md#where-the-failure-reason-is-written).

**Concurrency is the DPanel scheduled task's job.** The script has **no** mutex lock inside: one scheduled task per target is enough.
(Older versions of the script did have a lock, but that lock could be held for a long time by a leftover child process, which made every later round print "SKIP another task for the same update target is still running" and exit — it has been removed, see [Versions and upgrades](../README.en.md#versions-and-upgrades).)

## 2. How the compose mode updates

In essence it is "redeploy it with compose":

```sh
COMPOSE_PROJECT_NAME=<project> \
COMPOSE_FILE=<the original config> \
COMPOSE_ENV_FILES=<the original env> \
docker compose up -d --force-recreate
```

- **The project name, the config file and the env file are all read from the labels of the running container**, so the redeployment is exactly the same as the original one.
- Those parameters are passed through **environment variables** instead of the `-p` / `-f` / `--env-file` command line arguments. Reason: when the command line is assembled as a string, a path containing a space makes compose **print the Usage help and still return `rc=0`** (a silent failure, hit in practice). Passing them via environment variables does not have that problem, and it also does not rely on the current directory to guess the project name.
- With several compose files, `COMPOSE_PATH_SEPARATOR=,` declares the separator explicitly, so that a path containing a colon is not split apart.
- **`--remove-orphans` is not used**: it would delete containers of the same project that are not in the compose file but are still running.
- The health gate checks **all the containers in the project** (those with a healthcheck must report `healthy`; those without one must still be running 30 seconds after start).
- Rollback = restore the tag to the version from before the update and `up` once more; after the rollback it also re-checks that the containers really run the old image.

## 3. How the container mode updates

Instead of assembling arguments for `docker run`, it **rebuilds the container from the old one's declarative configuration**:

1. Rename the old container to `<name>__old_<timestamp>` (**it keeps running at this point, so the service is not interrupted**)
2. Stop the old one
3. Take the old container's `Config` + `HostConfig` + the actual mounts + the network declarations and create a new container through the Docker API **under the original name**
4. **Before starting it**, verify item by item that the new container's specification matches the old one (image, command, environment, ports, mounts, networks, restart policy, resource limits…)
5. Start it → health gate (containers without a healthcheck get a 30 second observation window)
6. On success → record the rollback point and delete the older `__old_*` copy (only one copy is kept)

A few deliberate choices:

- **The runtime `NetworkSettings` as a whole is not fed back** (it contains the container ID and the auto-assigned MAC/IP; feeding it back causes conflicts). The network is rebuilt from the declarations, and the auto-generated MAC/IP is reassigned.
- **The actual mounts are turned into explicit `Mounts`**, using the real name of an anonymous volume. That way the rebuilt container mounts the same volume instead of getting a new one and losing the data.
- **Everything is done by container ID, not by name.** The name is briefly taken during the rename, so working by ID is the only way to be sure you are not touching the wrong object.
- A rollback is "rename the old container back to its original name and start it"; the old container is kept around the whole time, so the rollback is fast.

## 4. What is skipped outright (`SKIP`)

These are not failures, they are the script deliberately refusing to act. The log says exactly why.

| Situation | Why it is skipped |
|---|---|
| The container belongs to a Compose project | You should use `--compose` and let compose do the rebuild, otherwise compose's metadata ends up inconsistent |
| The container has `AutoRemove=true` | Stopping the old container would delete it, and then the rollback copy would be gone |
| The container has `NetworkMode=container:<another container>` | It shares another container's network stack, and rebuilding it alone would break the chain |
| Another container depends on it via `--network container:` or a legacy link | Same reason: rebuilding would break those dependencies |
| It uses `VolumesFrom` | The mount semantics cannot be reproduced reliably |
| A mount carries an SELinux `z/Z` (and is not a volume) or another Mode that cannot be preserved | The permission semantics would change after the rebuild |
| A volume uses a custom driver | The behaviour of a non-local driver cannot be guaranteed |
| The network driver is not bridge/host/null | Rebuilding an unusual network (such as macvlan) is risky |
| The network has a MAC but no IPv4 | You cannot tell an auto-generated MAC from a user-specified one |
| The container is not `running` right now | There is no point in messing with a container that is stopping |
| The image reference is a digest (`repo@sha256:…`) | A pinned digest means "this must not change", so there is no such thing as "a new version" |
| The target is the container the script itself runs in | Updating itself would kill the executing process |
| The remote version is still within its `:bad` pinning period | This version is known to be broken, so it is left alone for now |

Two extra rules in compose mode:

- **Some container in the project is not running** → the whole round is skipped. That avoids treating "a one-off / deliberately stopped service" as a normal state and rebuilding it.
- **The same image runs at different versions inside the project** (some containers on the new version, some on the old one) → skipped, with a hint to unify them by hand first.

## 5. What it cannot protect (important)

### Data is not rolled back

A rollback only restores the **container and the image**. Migrations, writes and schema changes that the new version has already applied to a data volume or a database are **not** undone by the rollback.

> For containers running a database or any other stateful service, keep a separate backup. The script can guarantee "the container is back on the old image"; it cannot guarantee "the data is back in the old state".

### Healthy ≠ business correct

The script can only judge "the container is healthy". When the image ships a healthcheck that judgement is fairly reliable; **without a healthcheck it only watches for 30 seconds whether the container is still running**, which is blind to:

- a container that crashes 40 seconds after start-up
- a container that starts but cannot reach its database and returns 500
- a container that starts but begins writing bad data

For such services it is recommended to add a healthcheck in the Compose file, otherwise the gate means very little.

### It only recognises "did the tag change"

The decision is based on comparing the remote digest with the running image. If upstream **reuses the same tag without changing the content**, or if you reference a pinned digest, the script considers itself up to date — that is correct behaviour, not a missed update.

### It only handles "one new version"

If upstream jumps several versions at once, the script only pulls the newest one and does not step through them one by one. Upgrades across major versions (for example a database schema that requires a migration per version) have to be arranged by you.

## 6. What the scene looks like after a failure

| Exit code | The scene |
|---|---|
| `0` | Clean. The temporary `:rollback-pending` is removed and orphan images are cleaned up (`--dry-run` is the exception: a dry run changes nothing, so it cleans up nothing) |
| `1` | **Neither the container nor the images were touched**, everything is exactly as it was, so you can just run it again. This covers two situations: it stopped before doing anything (the pull failed, the remote could not be reached, the budget was not enough), and **the new version was unhealthy but the automatic rollback succeeded** — the latter leaves the scene in the state directory (`create.json`, the old and new specs, `pull.log`) for you to investigate, and the end of the log says `回滚现场已保留在 …` ("the rollback scene has been preserved in …") |
| `2` | The rollback itself failed. The state directory (by default `/tmp/.container-autoupdate`) is **kept on purpose**; it holds the old and new container IDs, the original image ID and the rename record, so a human can take over |
| `3` | **A breaking change**: your invocation is no longer valid. The script stopped before doing anything and changed nothing. Just follow the "migration path" in the log and fix the command |

`2` is the only case that really requires a human to take over (`3` also needs you to act, but you only have to edit the command — the container itself was never touched). Typical causes: Docker itself is unresponsive, the disk is full, the old container was deleted by someone else. Do not rush to reboot the machine and do not run `docker system prune` — the information you need is in the state directory.

## 7. Rollback point and bad-version pinning

- The rollback point is the tag `<image repository>:prev`, and **only one copy is kept**; it always points at "the last version known to run healthily".
- It is moved only after a successful update; when an update fails it stays where it is, so you can go back to the previous version at any time.
- A failed new version is pinned as `<image repository>:bad` and is not attempted again for 7 days by default (change it with `--bad-ttl-days`). That way, when upstream publishes a broken version, you do not retry it every hour and keep taking the service down.
- To release the pin immediately: `docker rmi <image repository>:bad`.

Manual rollback:

```sh
# Compose mode (enter the project directory; the project name can be read from the docker inspect label)
cd /path/to/project-dir
docker tag <image repository>:prev <image repository>:latest
docker compose up -d --force-recreate

# Container mode
docker rm -f <container name>
docker rename <container name>__old_<timestamp> <container name>
docker start <container name>
```
