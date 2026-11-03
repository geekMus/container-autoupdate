# How it works

> Language: [English](how-it-works.en.md) | [中文](how-it-works.md)

This document covers two things: what one round actually does, and **what it cannot guarantee**.

## What one round does

1. Parse arguments and decide the target (container mode or Compose mode — exactly one).
2. Check dependencies: `timeout`, `sed`, `awk`, `grep`; Compose mode also needs `docker` and the Compose v2 plugin (`docker compose version`).
3. Hand the work to the executor: DPanel CLI in container mode, `docker compose` in Compose mode.
4. Report the result honestly, log the elapsed time, exit with a code that matches what happened.

The script does **not** pull images itself, recreate containers, judge health, or move a `:prev` tag — DPanel or compose does that.

## Container mode

```
dpanel container:upgrade --name <container>              # check only
dpanel container:upgrade --name <container> --upgrade    # run only if newer
```

- Without `--upgrade`, DPanel returns one JSON object; the script continues only when `upgrade` is `true`.
- Success is judged **from the JSON only**: `code` ≥ 400, `status=failed`, or a non-empty `error` means failure. DPanel exits 0 even on failure, so the exit code alone would be wrong.
- On upgrade DPanel pulls the image, recreates the container and judges health; it rolls back by itself when the image is broken. It also keeps a `<container>-bak-<timestamp>` backup container — that is the rollback point.
- `--dry-run`: only the "check" step runs; if a new version exists it prints it and stops.

## Compose mode

```
docker compose pull      # only a pull can bring a new version
docker compose up -d     # only after a successful pull
```

- The project directory is discovered from container labels (`com.docker.compose.project.working_dir` and friends); `--compose-dir` / `COMPOSE_DIR` is the fallback.
- Compose parameters go through environment variables (`COMPOSE_PROJECT_NAME`, `COMPOSE_FILE`, `COMPOSE_PATH_SEPARATOR`, `COMPOSE_ENV_FILES`), never a command line — with a space in the path compose prints its usage and still returns 0.
- **No `--remove-orphans`**, and no manual tag/create/rm.
- The report distinguishes three states instead of lumping them together:
  - `已重建：<name>（old12 → new12）` — the image really changed
  - `新建：<name>` — the container did not exist before the deploy (first deploy or a newly added service)
  - `已是最新（拉取后没有容器需要重建）` — nothing needed rebuilding
- `pull` fails → rc=1 and **no** `up -d`; the project stays as it was.
- `--dry-run`: only lists the images involved; nothing is pulled or deployed.

## When it does nothing

| Situation | Behaviour |
|---|---|
| No target given, or both targets given | rc=1, nothing done |
| Bad argument or environment variable | rc=1, nothing done |
| Remaining budget below `DP_MIN_UPGRADE` | rc=1, no pull, no deploy |
| Container mode: DPanel reports latest | rc=0, nothing done |
| Compose mode: `pull` failed | rc=1, no deploy |

## What failure looks like

- The failure reason goes to **the real stderr** (a failing DPanel scheduled task keeps stderr and discards stdout; otherwise all you see is `exit status 1`).
- Container mode: the failure happened inside DPanel, which handles the container and image itself (it rolls back).
- Compose mode: neither a failed `pull` nor a failed `up -d` leaves a half-new project — nothing changed before `up -d`, and when `up -d` fails compose prints its own error while containers still run the previous version.
- If some container is not running after `up -d`, the script returns rc=1 and names each one.

## Time budget

One round is capped by `T_HARD` (540s by default), and every call is narrowed to the remaining budget:

| Variable | Default | Used for |
|---|---|---|
| `DP_T_CHECK` | 120 | Container mode: check |
| `DP_T_UPGRADE` | 420 | Container mode: upgrade |
| `DP_T_PULL` | 420 | Compose mode: `pull` |
| `DP_T_UP` | 180 | Compose mode: `up -d` |
| `DP_MIN_UPGRADE` | 90 | Do nothing below this remaining budget |

The scheduled task's timeout must be **clearly larger** than the internal limits (600s recommended): a round killed from outside logs nothing at all.

## What it cannot protect

- **Data is not rolled back**: containers and images can be, but a data migration the new program already ran cannot.
- **Healthy is not the same as correct**: Compose mode only knows the containers started, not that the application works.
- **Health judging belongs to the executor**: in container mode the health gate is DPanel's, not the script's.
- **Compose mode has no "check only"**: `docker compose pull` is the check; `--dry-run` can only list images.
- **It never talks to a registry**: whether an image can be pulled depends on the daemon and the mirror.
- **One new version at a time**: when several releases were skipped it only deals with the newest.
