# container-autoupdate

一个给 **DPanel 计划任务** 用的容器自动更新脚本，单文件，放在 dpanel 容器里跑（只用 `sh`；依赖 `timeout`、`sed`、`awk`、`grep`，Compose 模式另需 `docker` + Compose v2 插件）。

它自己不做危险动作：容器交给 DPanel 升级，Compose 交给 `docker compose` 重新部署。

## 这是什么

跑一次 = 检查一次。**频率、启停、超时全交给 DPanel 的「计划任务」**，脚本里没有任何定时逻辑。

- **容器模式**：问 DPanel「这个容器有新版吗」，有就让 DPanel 升级（它会留一个 `<容器名>-bak-<时间戳>` 备份容器，那就是回滚点）。
- **Compose 模式**：`docker compose pull` 拉一次，有变化才 `up -d` 就地重建。项目目录从容器标签自动认，认不到再用 `--compose-dir` 指定。

## 安装（DPanel 计划任务）

在 DPanel 里新建一个计划任务，脚本框整段填下面这段（按小时跑，执行超时设 600 秒）：

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

- `SRC` 里一行一个源，只写站点域名，按顺序试，**内容合格才算成功**（不只看 exit code，`gh-proxy.net` 那种返回 HTML 的会被挡掉）。
- 镜像站那条会拼成「站点/原始 GitHub 地址」；`https://github.com` 那条是直连（GitHub 能通时最快）。
- 全部失败时沿用上一轮的 `/tmp/container-autoupdate.sh`，照样能跑；连副本都没有才报错退出（rc=1）。
- 不用 `curl … | sh`：管道会把下载失败吞掉。
- 想锁死版本：把 `G` 里的 `latest/download` 换成 `download/v4.0.1`。

## 两种模式

| 目标 | 更新动作 | 回滚点 |
|---|---|---|
| 容器（`--container`） | `dpanel container:upgrade`（先检查，有新版才升级） | DPanel 生成的 `<容器名>-bak-<时间戳>` 备份容器 |
| Compose（`--compose`） | `docker compose pull` + `docker compose up -d` | 旧镜像还在本地：`docker tag <旧镜像ID> <repo>:latest && docker compose up -d --force-recreate` |

## 常用参数

| 参数 | 说明 |
|---|---|
| `--compose <名>` | Compose 项目名（DPanel 里那个名字） |
| `--container <名>` | 单个容器名 |
| `--compose-dir <路径>` | 项目目录；不填则从容器标签自动认 |
| `--dry-run` | 只检查不动手：容器模式问 DPanel，Compose 模式只列镜像 |
| `--dpanel-container <名>` | DPanel 容器名，默认 `dpanel` |
| `--dpanel-bin <路径>` | DPanel CLI 路径，默认 `/app/server/dpanel` |
| `--docker-sock <路径>` | 指定 Docker socket |
| `-h` / `-V` | 帮助 / 版本 |

`--compose` 与 `--container` 只能给一个。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | 空 | 同 `--compose` / `--container` |
| `COMPOSE_DIR` | 空 | 同 `--compose-dir` |
| `DOCKER_SOCK` / `DOCKER_HOST` | 空 | 传给 docker CLI |
| `DPANEL_NAME` / `DPANEL_BIN` / `DPANEL_DOCKER_ENV` | `dpanel` / `/app/server/dpanel` / `local` | DPanel 相关 |
| `T_HARD` | 540 | 整轮时间硬上限（秒） |
| `DP_T_CHECK` / `DP_T_UPGRADE` | 120 / 420 | 容器模式：查版本 / 升级 的等待上限 |
| `DP_T_PULL` / `DP_T_UP` | 420 / 180 | Compose 模式：`pull` / `up -d` 的等待上限 |
| `DP_MIN_UPGRADE` | 90 | 剩余预算低于这个值就不动手 |
| `DRY_RUN` | 0 | 同 `--dry-run` |

## 试运行与回滚

先跑一轮 `--dry-run`，确认脚本认到的项目名、目录、镜像都对：

```sh
docker exec -it dpanel sh -c 'sh /tmp/container-autoupdate.sh --compose myapp --dry-run'
```

容器回滚：DPanel 网页里用 `<容器名>-bak-<时间戳>` 恢复，或 `docker stop/rm <名>` 后 `docker rename <名>-bak-<ts> <名>` 再 `docker start <名>`。

Compose 回滚：旧镜像还在本地，`docker tag` 回 `:latest` 再 `up -d` 即可（脚本不维护 `:prev`，也不做数据回滚）。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功，或没有新版本 |
| 1 | 配置/环境错误，或本轮没更新成功（目标保持原样） |
| 130 | 被 Ctrl-C 中断 |
| 143 | 被 SIGTERM / SIGHUP 中断（计划任务超时常见） |

## 更多文档

- [它怎么工作、保护不了什么](docs/how-it-works.md)
- [全部参数与环境变量](docs/parameters.md)
- [计划任务写法、排查、常见问题](docs/advanced-usage.md)
- [发版流程（维护者）](docs/releasing.md)
- 排查残留进程和旧锁文件：`curl -fsSL -L https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh -o /tmp/ct-stale-lock-check.sh && sh /tmp/ct-stale-lock-check.sh`
