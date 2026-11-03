# 参数与环境变量

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--compose <名>` | — | Compose 项目名（DPanel 里那个名字）。与 `--container` 互斥 |
| `--container <名>` | — | 单个容器名。与 `--compose` 互斥 |
| `--compose-dir <路径>` | 自动反查 | Compose 项目目录；反查不到时才需要它 |
| `--docker-sock <路径>` | 空 | 传给 docker CLI 的 socket |
| `--dpanel-container <名>` | `dpanel` | DPanel 容器名 |
| `--dpanel-bin <路径>` | `/app/server/dpanel` | DPanel CLI 在容器里的路径 |
| `--dpanel-docker-env <名>` | `local` | DPanel 里的 docker 环境名 |
| `--dry-run` | 关 | 只检查不动手 |
| `-h` / `--help` | — | 显示帮助 |
| `-V` / `--version` | — | 显示版本 |

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | 空 | 同 `--compose` / `--container` |
| `COMPOSE_DIR` | 空 | 同 `--compose-dir` |
| `DOCKER_SOCK` | 空 | 同 `--docker-sock` |
| `DOCKER_HOST` | 空 | 直接传给 docker CLI |
| `DPANEL_NAME` / `DPANEL_BIN` / `DPANEL_DOCKER_ENV` | `dpanel` / `/app/server/dpanel` / `local` | 同对应参数 |
| `DRY_RUN` | `0` | 同 `--dry-run` |
| `T_HARD` | `540` | 整轮时间硬上限（秒） |
| `DP_T_CHECK` | `120` | 容器模式：查版本的等待上限（旧名 `T_INSPECT` 仍认） |
| `DP_T_UPGRADE` | `420` | 容器模式：升级的等待上限 |
| `DP_T_PULL` | `420` | Compose 模式：`docker compose pull` 的等待上限 |
| `DP_T_UP` | `180` | Compose 模式：`docker compose up -d` 的等待上限 |
| `DP_MIN_UPGRADE` | `90` | 剩余预算低于这个值就不动手 |

命令行参数优先于同名环境变量。每个等待上限还会被剩余预算进一步收紧。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功，或没有新版本 |
| 1 | 配置/环境错误，或本轮没更新成功（目标保持原样） |
| 130 | 被 Ctrl-C（SIGINT）中断 |
| 143 | 被 SIGTERM / SIGHUP 中断（计划任务超时常见） |
