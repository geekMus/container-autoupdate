# Advanced usage

> Language: [English](advanced-usage.en.md) | [中文](advanced-usage.md)

## DPanel scheduled task

Create a scheduled task → hourly (or whatever frequency you want) → **set the execution timeout to 600s** → paste the whole block below into the script box:

```sh
SRC='https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
https://ghfast.top/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh'
T=/tmp/ct-new.sh
okfile() { [ "$(wc -c <"$1" 2>/dev/null || echo 0)" -gt 1000 ] && sh -n "$1" 2>/dev/null && grep -q container-autoupdate "$1"; }
for u in $SRC; do
  curl -fsSL --max-time 30 "$u" -o "$T" 2>/dev/null || continue
  okfile "$T" && break
done
okfile "$T" && mv -f "$T" /tmp/container-autoupdate.sh
[ -s /tmp/container-autoupdate.sh ] || { echo "ERR 拿不到可用的更新脚本"; exit 1; }
sh /tmp/container-autoupdate.sh --compose myapp
```

- Never write `curl … | sh`: the pipeline reports `sh`'s status, so a download failure is swallowed.
- To pin a version: replace `latest/download` with `download/v4.0.0` on every line of `SRC`.
- One scheduled task per target; the script holds no lock.

## Running one round by hand

```sh
docker exec -it dpanel sh -c 'sh /tmp/container-autoupdate.sh --compose myapp --dry-run'
```

Drop `--dry-run` to really run one round (it exits when done; there is no daemon).

## Several projects

One scheduled task per project, each with its own `--compose`. To handle several in one task, just add lines:

```sh
sh /tmp/container-autoupdate.sh --compose myapp
sh /tmp/container-autoupdate.sh --compose web
```

Different projects do not interfere; never run two rounds for the same project at once (the script does not lock).

## Logs and troubleshooting

- Every round starts with `container-autoupdate v<version> 启动`, so you can tell which version ran.
- Failure reasons go to **the real stderr**, so the DPanel task log shows the actual text instead of just `exit status 1`.
- To see what the script resolved (project name, directory, images, containers), run one round with `--dry-run`.
- Leftover files inside the container can be inspected with the read-only script: `sh /tmp/ct-stale-lock-check.sh` (download link in the [README](../README.en.md#more-documentation)).

## FAQ

| Symptom | Cause and fix |
|---|---|
| `ERR 找不到 Compose 项目 X 的项目目录` | The project was never deployed, or its containers were `down`-ed. Pass `--compose-dir`, or run `docker compose up -d` once by hand |
| `ERR 无法执行 docker compose（缺 compose 插件？）` | The Compose v2 plugin is missing; install it |
| `ERR DPanel 返回了错误` | DPanel failed while pulling or recreating; read the original error that follows |
| It keeps saying "latest" although a newer image exists | The mirror is stale, or the tag did not move (nothing pushed to `:latest`) |
| The task is marked failed but the log only shows `exit status 1` | The reason is on stderr; only very old versions printed nothing else — since v1.1.2 the original text is included |
| How to roll back | Container: use DPanel's `<container>-bak-<timestamp>` backup container. Compose: tag the old image back to `:latest` and run `up -d` |
