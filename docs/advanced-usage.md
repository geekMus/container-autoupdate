# 进阶用法

## DPanel 计划任务

新建计划任务 → 执行周期选每小时（或你要的频率）→ **执行超时设 600 秒** → 脚本框整段填下面这段：

```sh
G=https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
SRC='https://gh-proxy.com
https://ghfast.top
https://github.com'
T=/tmp/ct-new.sh
okfile() { [ "$(wc -c <"$1" 2>/dev/null || echo 0)" -gt 1000 ] && sh -n "$1" 2>/dev/null && grep -q container-autoupdate "$1"; }
for u in $SRC; do
  case "$u" in "https://github.com") url=$G ;; *) url="$u/$G" ;; esac
  curl -fsSL --max-time 30 "$url" -o "$T" 2>/dev/null || continue
  okfile "$T" && break
done
okfile "$T" && mv -f "$T" /tmp/container-autoupdate.sh
[ -s /tmp/container-autoupdate.sh ] || { echo "ERR 拿不到可用的更新脚本"; exit 1; }
sh /tmp/container-autoupdate.sh --compose myapp
```

- 不要写 `curl … | sh`：管道的退出码是 `sh` 的，下载失败会被吞掉。
- `SRC` 只写站点域名；镜像站那条会拼成「站点/原始 GitHub 地址」，`https://github.com` 那条是直连。
- 想锁版本：把 `G` 里的 `latest/download` 换成 `download/v4.0.1`。
- 同一目标只挂一个计划任务；脚本内部没有锁。

## 手动跑一轮

```sh
docker exec -it dpanel sh -c 'sh /tmp/container-autoupdate.sh --compose myapp --dry-run'
```

去掉 `--dry-run` 就是真跑一轮（跑完即结束，没有常驻进程）。

## 多个项目

一个项目一个计划任务、一个 `--compose`。想在一个任务里跑多个项目，就写多行：

```sh
sh /tmp/container-autoupdate.sh --compose myapp
sh /tmp/container-autoupdate.sh --compose web
```

不同项目互不影响；同一个项目别同时跑两个（脚本不加锁）。

## 日志与排查

- 脚本每轮首行都打 `container-autoupdate v<版本> 启动`，方便确认跑的是哪一版。
- 失败原因会写到**真正的 stderr**，DPanel 任务日志里能看到原文，而不是只有 `exit status 1`。
- 想知道脚本认到了什么（项目名、目录、镜像、容器），加 `--dry-run` 跑一轮看日志。
- 容器里残留的旧文件用只读脚本查：`sh /tmp/ct-stale-lock-check.sh`（下载地址见 [README](../README.md#更多文档)）。

## 常见问题

| 现象 | 原因与处理 |
|---|---|
| `ERR 找不到 Compose 项目 X 的项目目录` | 项目还没部署过，或容器被 `down` 掉了。用 `--compose-dir` 指定，或先手动 `docker compose up -d` 一次 |
| `ERR 无法执行 docker compose（缺 compose 插件？）` | 缺 Compose v2 插件，装好再跑 |
| `ERR DPanel 返回了错误` | DPanel 那边拉镜像/重建失败，看后面的原始报错 |
| 一直报「已是最新」但其实有新版本 | 镜像源没更新，或 tag 没变（`:latest` 没推新的） |
| 计划任务显示失败但日志里只有 `exit status 1` | 失败原因在 stderr；v1.1.2 起会带上原文（若还只看到一句，说明跑的是更早的版本） |
| 想回滚 | 容器：用 DPanel 的 `<容器名>-bak-<时间戳>` 备份容器；Compose：把旧镜像 tag 回 `:latest` 再 `up -d` |
