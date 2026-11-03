# 它怎么工作

> 语言：[中文](how-it-works.md) | [English](how-it-works.en.md)

这份文档讲清楚两件事：每一轮到底做了什么，以及**哪些事它保证不了**。

## 一轮都做什么

1. 解析参数，确定这一轮的目标（容器模式还是 Compose 模式，两者只能选一个）。
2. 检查依赖：`timeout`、`sed`、`awk`、`grep`；Compose 模式还要有 `docker` 与 Compose v2 插件（`docker compose version`）。
3. 把活交给执行者：容器模式交给 DPanel CLI，Compose 模式交给 `docker compose`。
4. 如实报告结果，写一行总耗时，按结果给退出码。

脚本自己**不拉镜像做校验、不重建容器、不判健康、不打 `:prev` 标签**——这些都交给 DPanel 或 compose。

## 容器模式

```
dpanel container:upgrade --name <容器名>              # 只检查
dpanel container:upgrade --name <容器名> --upgrade    # 有新版才执行
```

- 不带 `--upgrade` 时，DPanel 返回一个 JSON；只有 `upgrade` 为 `true` 才继续。
- 判断成败**只看 JSON**：`code` ≥ 400、`status=failed`、或 `error` 非空 = 失败。DPanel 失败时退出码仍是 0，看退出码会误判。
- 升级时 DPanel 自己拉镜像、重建容器、判健康；不健康它会自回滚。它还会留一个 `<容器名>-bak-<时间戳>` 备份容器，那就是回滚点。
- `--dry-run`：只做「检查」那一步，有新版就打印「发现新版本」，不动手。

## Compose 模式

```
docker compose pull      # 有变化才可能有新版本
docker compose up -d     # 只在 pull 成功后才执行
```

- 项目目录优先从容器标签反查（`com.docker.compose.project.working_dir` 等）；反查不到才用 `--compose-dir` / `COMPOSE_DIR`。
- compose 参数走环境变量（`COMPOSE_PROJECT_NAME`、`COMPOSE_FILE`、`COMPOSE_PATH_SEPARATOR`、`COMPOSE_ENV_FILES`），不拼命令行——路径含空格时 compose 会打印 Usage 却返回 0。
- **不加 `--remove-orphans`**，也不手工 tag/create/rm。
- 报告分三态，不混为一谈：
  - `已重建：<名>（旧12位 → 新12位）`——镜像真的换了
  - `新建：<名>`——部署前没有这个容器（首次部署或新加的服务）
  - `已是最新（拉取后没有容器需要重建）`
- `pull` 失败 → 直接 rc=1，**不会**执行 `up -d`，项目保持原样。
- `--dry-run`：只列这个项目涉及的镜像，不拉取、不部署。

## 什么情况不动手

| 情况 | 行为 |
|---|---|
| 没有给出目标，或两个目标同时给 | rc=1，什么都不做 |
| 参数/环境变量写错 | rc=1，什么都不做 |
| 剩余预算低于 `DP_MIN_UPGRADE` | rc=1，不拉不部署 |
| 容器模式：DPanel 说已是最新 | rc=0，什么都不做 |
| Compose 模式：`pull` 失败 | rc=1，不部署 |

## 失败了会怎样

- 失败原因写到**真正的 stderr**（DPanel 计划任务失败时只保留 stderr、丢弃 stdout，否则你只会看到一句 `exit status 1`）。
- 容器模式：失败发生在 DPanel 那边，容器与镜像由 DPanel 处理（它会自回滚）。
- Compose 模式：`pull` 失败或 `up -d` 失败都不留半新半旧——`up -d` 之前项目没被改过；`up -d` 失败时 compose 会报出原话，容器仍是上一版。
- `up -d` 之后如果有容器没在运行，脚本 rc=1 并逐个点名。

## 时间预算

一轮的硬上限是 `T_HARD`（默认 540 秒），每次调用还会按剩余预算收敛：

| 变量 | 默认 | 用于 |
|---|---|---|
| `DP_T_CHECK` | 120 | 容器模式：查版本 |
| `DP_T_UPGRADE` | 420 | 容器模式：升级 |
| `DP_T_PULL` | 420 | Compose 模式：`pull` |
| `DP_T_UP` | 180 | Compose 模式：`up -d` |
| `DP_MIN_UPGRADE` | 90 | 剩余预算低于此值就不动手 |

计划任务的执行超时要**明显大于**内部上限（推荐 600 秒）：被外部 SIGKILL 的那一轮日志里什么都没有。

## 它保护不了什么

- **数据不回滚**：容器和镜像能回滚，新程序已经做过的数据迁移不能。
- **健康 ≠ 业务正确**：Compose 模式只保证容器跑起来了，业务是否正常它不知道。
- **健康判断交给执行者**：容器模式的健康门禁是 DPanel 的，不是脚本的。
- **Compose 模式没有「只检查」**：`docker compose pull` 本身就是判断，`--dry-run` 只能列镜像。
- **不碰 Registry**：镜像能不能拉到，取决于 daemon 与镜像源。
- **一次只处理一个新版本**：跨几个版本时它只管最新那一版。
