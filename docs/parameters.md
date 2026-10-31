# 全部参数与环境变量

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

## 全部命令行参数

| 参数 | 默认 | 什么时候需要它 |
|---|---|---|
| `--compose <名>` | 无 | Compose 模式必填 |
| `--container <名>` | 无 | 容器模式必填 |
| `--compose-dir <目录>` | 自动发现 | **Compose 项目目录无法从容器 label 发现时**。正常情况脚本会从运行中容器的 label 读出目录，不用填。项目当前一个容器都没在跑、或容器是特殊方式创建时报错提示「请用 --compose-dir 指定项目目录」，这时加它 |
| `--docker-sock <路径>` | `DOCKER_HOST` 或 `/var/run/docker.sock` | Docker socket **不在默认位置**时。rootless Docker（`/run/user/1000/docker.sock`）、Docker 在另一台机器、socket 挂载在非常规路径 |
| `--state-dir <目录>` | `/tmp/.container-autoupdate` | `/tmp` 重启会被清空、而你希望中断后跨重启也能恢复；或 `/tmp` 空间紧张；或想让多个用户的任务互不干扰 |
| `--bad-ttl-days <天>` | `7` | 坏版本钉住期。某个新版本反复起不来、你想更快重试就调小（如 `1`），想更保守就调大 |
| `--dry-run` | 关 | 只检查不改动。**首次接入**、排查「为什么没更新」、确认某容器会被怎么处理 |
| `-h` / `--help` | — | 显示帮助 |
| `-V` / `--version` | — | 显示版本号 |

## 全部环境变量

| 变量 | 对应参数 | 什么时候需要它 |
|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | `--compose` / `--container` | DPanel 的 Environment 面板、systemd 的 `Environment=`、或一条命令服务多个目标 |
| `COMPOSE_DIR` | `--compose-dir` | 同上 |
| `COMPOSE_BASE` | — | Compose 目录的**回退根路径**，脚本会尝试 `$COMPOSE_BASE/<项目名>`。只在自建环境里用，DPanel 用户不需要 |
| `DOCKER_SOCK` | `--docker-sock` | 同上 |
| `DOCKER_HOST` | — | 已设这个标准变量的话脚本直接用它，支持 `unix:///path` 与 `tcp://host:port` |
| `DRY_RUN=1` | `--dry-run` | 同上 |
| `BAD_TTL_DAYS` | `--bad-ttl-days` | 同上 |
| `STATE_ROOT` | `--state-dir` | 同上 |
| `LOCK_PREFIX` | `/tmp/.container-autoupdate` | 互斥锁文件前缀。同一台机器跑多份脚本副本、想让它们各管各的锁时改它 |

## 超时参数

**一般不用改。** 改之前必须确认：脚本自身硬上限（`T_HARD`）要小于外部定时器的超时。

| 变量 | 默认 | 含义 | 什么时候调 |
|---|---|---|---|
| `T_HARD` | 540 秒 | 全脚本硬上限 | 外部定时器超时更短时，调小 |
| `T_INSPECT` | 30 秒 | 查远端 digest 的超时 | 镜像仓库响应慢 |
| `T_STALL` | 60 秒 | 拉取**进度停滞**判定：这么久没有新字节就判卡死并 kill | 网络特别慢、健康拉取也会长时间无输出时调大（如 `120`） |
| `T_PULL_MAX` | 300 秒 | 单次拉取的绝对上限 | 镜像很大 |
| `T_UP` | 60 秒 | 重建 / 启动容器的超时 | 容器启动慢 |
| `T_HEALTH` | 120 秒 | 健康门禁等待上限 | 应用启动慢（Java 服务常见）时调大，同时加大外部超时 |
| `HEALTH_TRIES` | 12 | 健康检查轮询次数 | 配合 `T_HEALTH` 调整 |
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
| 应用启动很慢（>120 秒才 healthy） | `T_HEALTH=300 T_HARD=540`，外部超时同步加到 600+ |
| 镜像仓库经常卡住不返回 | `T_STALL=120`（别调太小，健康拉取也可能长时间静默） |
| 同一个新版本反复失败，想快点重试 | `--bad-ttl-days 1` |
