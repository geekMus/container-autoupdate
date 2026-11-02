# 全部参数与环境变量

> 脚本是给 **DPanel 计划任务**用的：跑一轮就结束，频率与并发交给 DPanel。
> 同一目标只挂一个计划任务即可（脚本内部不再加互斥锁）。
> 手动运行也允许，那只是单次运行；不建议再套 cron / systemd timer。

## 指定目标

两种目标**必须且只能指定一个**。

| 参数 | 说明 |
|---|---|
| `--compose <项目名>` | Compose 项目名，即 `docker compose` 的 project name（通常是目录名，`docker compose ls` 能看到） |
| `--container <容器名>` | 容器名，即 `docker ps` 里的 `NAMES` |

三种指定方式，优先级：**命令行 > 环境变量 > 脚本顶部配置区**。

```sh
# 1. 命令行
container-autoupdate.sh --compose myapp

# 2. 环境变量
UPD_COMPOSE=myapp container-autoupdate.sh

# 3. 改脚本顶部配置区（适合固定用途）
COMPOSE_NAME="myapp"
CONTAINER_NAME=""
```

## 依赖

脚本在动手前会自检，缺任何一项都直接 `ERR 缺少依赖命令：xxx` 并以退出码 `1` 结束，
不会跑到一半才炸。

| 命令 | 用途 | 常见缺失场景 |
|---|---|---|
| `docker` | 一切操作的前提 | — |
| `docker buildx` | **查远端 digest 的唯一手段**（`docker buildx imagetools inspect`） | 精简安装的 Docker、只装了 `docker.io` 包的系统。缺它时脚本在动手前就报错——否则每轮都会误报「无法获取远端 digest」，把人引向网络问题 |
| `curl` | 拉取镜像走 Docker Engine API 流（判断进度停滞）、查远端 digest | 极简镜像 |
| `timeout` | 每个外部调用都有超时，防止整轮被计划任务的执行超时 SIGKILL | busybox 有；某些精简镜像无 |
| `sed` `awk` `grep` | 解析 `docker inspect` 输出 | busybox 全套足够，不需要 GNU 版 |

Docker 端还需要 **Compose v2 插件**（`docker compose`，不是老的 `docker-compose`），
仅 compose 模式需要；容器模式不需要。

## 引导器（ct-bootstrap.sh）的参数与环境变量

引导器是推荐的使用方式：它负责下载与缓存主脚本，你只维护一行命令。
它自己也需要 `curl`（探测与下载）和 `sh`，其余依赖同主脚本。

两种指定方式，优先级：**命令行 `--ct-*` > 环境变量 `CT_*`**。
引导器选项必须写在主脚本参数前面；也可用 `--` 明确分隔。

| 命令行 | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| `--ct-version <版本>` | `CT_VERSION` | 空 | **设了就是固定版本模式**（如 `1.2.3`，带不带 `v` 前缀都行）：不探测远端，本地有就直接跑，**完全不联网**。生产环境推荐设，版本号见 Releases 页面。 |
| `--ct-cache-dir <目录>` | `CT_CACHE_DIR` | `/var/cache/container-autoupdate` | 脚本缓存目录。容器内跑要挂载可写目录，或改到 `/tmp`。 |
| `--ct-cache-keep <N>` | `CT_CACHE_KEEP` | `3` | 保留几个历史版本文件，超出的删掉。设 `0` 表示不裁剪。 |
| `--ct-source <源>` | `CT_SOURCE` | `auto` | 下载源：`auto`（gh-proxy → 直连 → ghproxy.net）、`direct`、`gh-proxy`、`ghproxy`，或任意自定义前缀（会拼在 `https://github.com/...` 前面）。 |
| `--ct-t-net <秒>` | `CT_T_NET` | `20` | 单次网络操作超时（秒）。探测和下载各自适用。 |
| `--ct-tries <N>` | `CT_TRIES` | `2` | 每个源尝试几次。 |
| `--ct-force` | `CT_FORCE=1` | 关 | 忽略缓存强制重新下载。 |
| `--ct-quiet` | `CT_QUIET=1` | 关 | 不打印引导器自己的日志（主脚本日志照旧）。 |
| `--ct-help` | — | — | 显示引导器帮助。 |

```sh
# 命令行（推荐写进 DPanel 计划任务的脚本框）
ct-bootstrap.sh --ct-version 1.2.3 --compose myapp

# 环境变量（兼容旧写法）
CT_VERSION=1.2.3 ct-bootstrap.sh --compose myapp

# 混用：命令行覆盖环境变量；-- 后全是主脚本参数
CT_SOURCE=auto ct-bootstrap.sh --ct-source direct --ct-version 1.2.3 -- --compose myapp --dry-run
```

引导器行为一览：

| 情形 | 结果 |
|---|---|
| 已设固定版本（`--ct-version` / `CT_VERSION`）+ 本地有该版本 | 直接执行，**零网络请求** |
| 已设固定版本 + 本地没有 | 下载该版本后执行（只试固定 tag，不会拿 latest） |
| 未设固定版本 + 探测到版本且本地已有 | 只发一次 4KB Range 请求，不下载 |
| 未设固定版本 + 探测到新版本 | 下载 64KB 并缓存，然后执行 |
| 探测失败 + 本地有可用缓存 | 用缓存执行，打 `WARN`（退出码取决于主脚本） |
| 探测失败 + 本地无缓存 | `ERR`，退出码 `1`（**不会静默成功**） |
| 缓存文件损坏 | 自动重新下载（校验：语法 + `VERSION` 字段 + 特征字符串） |

> 为什么默认源是 `gh-proxy.com` 而不是直连：实测（2026-11-01）直连 `github.com`
> 偶发 DNS 失败与 12 秒延迟，`gh-proxy.com` 稳定 1~2 秒；`ghproxy.net` 已连续超时不可用。
> 想直连就设 `--ct-source direct` 或 `CT_SOURCE=direct`。


## 全部命令行参数

| 参数 | 默认 | 什么时候需要它 |
|---|---|---|
| `--compose <名>` | 无 | Compose 模式必填 |
| `--container <名>` | 无 | 容器模式必填 |
| `--compose-dir <目录>` | 自动发现 | **Compose 项目目录无法从容器 label 发现时**。正常情况脚本会从运行中容器的 label 读出目录，不用填。项目当前一个容器都没在跑、或容器是特殊方式创建时报错提示「请用 --compose-dir 指定项目目录」，这时加它 |
| `--docker-sock <路径>` | `DOCKER_HOST` 或 `/var/run/docker.sock` | Docker socket **不在默认位置**时。rootless Docker（`/run/user/1000/docker.sock`）、Docker 在另一台机器、socket 挂载在非常规路径 |
| `--state-dir <目录>` | `/tmp/.container-autoupdate` | `/tmp` 重启会被清空、而你希望中断后跨重启也能恢复；或 `/tmp` 空间紧张；或想让多个用户的任务互不干扰 |
| `--bad-ttl-days <天>` | `7` | 坏版本钉住期。某个新版本反复起不来、你想更快重试就调小（如 `1`），想更保守就调大 |
| `--compat <版本>` | 关 | **声明「我只验证到某个版本」**。脚本若比它新、且中间有破坏性变更，就硬停而不是冒险执行（退出码 `3`）。升级脚本后行为变了、你想先稳住现状时用它 |
| `--dry-run` | 关 | 只检查不改动：不动容器、不动镜像标签、不清理旧镜像（仅写状态目录）。**首次接入**、排查「为什么没更新」、确认某容器会被怎么处理 |
| `-h` / `--help` | — | 显示帮助 |
| `-V` / `--version` | — | 显示版本号 |

## 全部环境变量

| 变量 | 对应参数 | 什么时候需要它 |
|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | `--compose` / `--container` | DPanel 的 Environment 面板、或一条命令服务多个目标 |
| `COMPOSE_DIR` | `--compose-dir` | 同上 |
| `COMPOSE_BASE` | — | Compose 目录的**回退根路径**，脚本会尝试 `$COMPOSE_BASE/<项目名>`。只在自建环境里用，DPanel 用户不需要 |
| `DOCKER_SOCK` | `--docker-sock` | 同上 |
| `DOCKER_HOST` | — | 已设这个标准变量的话脚本直接用它，支持 `unix:///path` 与 `tcp://host:port` |
| `DRY_RUN=1` | `--dry-run` | 同上 |
| `BAD_TTL_DAYS` | `--bad-ttl-days` | 同上 |
| `COMPAT_UNTIL` | `--compat` | 同上 |
| `STATE_ROOT` | `--state-dir` | 同上 |

## 超时参数

**一般不用改。** 改之前必须确认：脚本自身硬上限（`T_HARD`）要小于 DPanel 计划任务的「执行超时」。

| 变量 | 默认 | 含义 | 什么时候调 |
|---|---|---|---|
| `T_HARD` | 540 秒 | 全脚本硬上限 | 计划任务超时更短时，调小 |
| `T_INSPECT` | 30 秒 | 查远端 digest 的超时 | 镜像仓库响应慢 |
| `T_STALL` | 60 秒 | 拉取**进度停滞**判定：这么久没有新字节就判卡死并 kill | 网络特别慢、健康拉取也会长时间无输出时调大（如 `120`） |
| `T_PULL_MAX` | 300 秒 | 单次拉取的绝对上限 | 镜像很大 |
| `T_UP` | 60 秒 | 重建 / 启动容器的超时 | 容器启动慢 |
| `T_HEALTH` | 120 秒 | 健康门禁**墙钟等待上限**（真正生效的那个） | 应用启动慢（Java 服务常见）时调大，同时加大 `T_HARD` 与计划任务「执行超时」 |
| `HEALTH_TRIES` | `0`（不设） | 健康检查**额外**的轮询次数硬上限；`0` 表示只受 `T_HEALTH` 秒数约束 | 只想限制轮询次数、不想动秒数时用 |
| `T_ROLLBACK` | 60 秒 | 回滚操作的超时 | 回滚慢 |
| `PLAIN_BOOT` | 30 秒 | **无 healthcheck** 的容器，启动后观察多久算稳定 | 启动慢的容器调大 |

## 常见场景怎么配

| 场景 | 配置 |
|---|---|
| 普通 Compose 项目 | `--compose myapp`，其余全默认 |
| 普通 docker run 容器 | `--container mycontainer`，其余全默认 |
| 项目容器全停了，脚本说找不到目录 | 加 `--compose-dir /path/to/project` |
| rootless Docker | 加 `--docker-sock /run/user/1000/docker.sock` |
| 想先看效果 | 加 `--dry-run` |
| 应用启动很慢（>120 秒才 healthy） | `T_HEALTH=300`（必要时 `T_HARD=600`），DPanel 计划任务的「执行超时」同步加到 700+ |
| 镜像仓库经常卡住不返回 | `T_STALL=120`（别调太小，健康拉取也可能长时间静默） |
| 同一个新版本反复失败，想快点重试 | `--bad-ttl-days 1` |
| 脚本升到新版、但你想先稳住现有行为 | `--compat <你验证过的版本>`，例如 `--compat 1.2.3` |

## 退出码

| 码 | 含义 | 该怎么办 |
|---|---|---|
| `0` | 成功 / 已是最新 / 按规则跳过 | 无需处理 |
| `1` | 配置或环境错误，或本轮未能完成更新（**容器保持原样**） | 看日志里的 `ERR`，修配置后重跑 |
| `2` | 回滚本身失败，**需要人工介入**（现场保留在 `--state-dir`） | 按日志提示手工恢复，再删掉状态目录 |
| `3` | **检测到破坏性变更**，你的调用方式已失效（本次未做任何改动） | 按日志里的「迁移方式」改命令；或锁版本；或加 `--compat` |
| `130` | 被 `SIGINT`（Ctrl-C）中断 | 手动跑时按了 Ctrl-C，无妨 |
| `143` | 被 `SIGTERM` / `SIGHUP` 中断（计划任务超时最常见） | 说明「执行超时」太短，调大它或调小 `T_HARD` |
