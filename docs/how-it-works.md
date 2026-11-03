# 工作方式与安全边界

> 语言：[中文](how-it-works.md) | [English](how-it-works.en.md)

> 这一页解释脚本**怎么做**、**什么情况会不动手**、**哪些事它保护不了**。用之前值得花三分钟读一遍。

## 1. 一句话说清它做什么

v2.0.0 起，脚本**不再自己拉镜像、不再自己重建容器**：它只做三件事 ——

1. **判断该不该更新**（问 DPanel「这个目标有没有新版本」）；
2. **把更新动作交给 DPanel 执行**；
3. **把 DPanel 的结果如实报出来**（成功 / 失败 / 无需更新）。

所有更新能力都来自 DPanel 自己的命令行：容器走 `container:upgrade`，Compose 项目走 `compose:deploy`。

为什么这么改：

- 自己重建容器要**准确复刻**网络、挂载（含匿名卷真实名字）、资源限制、重启策略、Capabilities……漏一处就是生产事故。v1.x 为此写了上千行，仍出过「拉取卡死被误判」「失败原因打两遍」这类问题。
- DPanel 本来就有这两件事的成熟实现，而且它的「备份容器」就是现成的回滚点。
- 脚本因此从 1700+ 行降到 700 行左右，逻辑面小，可控。

## 2. 前置条件

- **必须在装了 DPanel 的机器上用**：更新动作要靠 DPanel 的 CLI。
- **推荐在 DPanel 容器里跑**（DPanel 的「计划任务」默认就是在 `dpanel` 容器内执行）：脚本直接调用 `/app/server/dpanel`。
- 如果在宿主上跑（不在 dpanel 容器内）：需要宿主有 `docker` 命令，脚本会用 `docker exec dpanel /app/server/dpanel ...` 调用。可用 `--dpanel-container` 指定容器名（默认 `dpanel`）。
- **Compose 模式要求该项目已经在 DPanel 里登记过**（DPanel 网页 → Compose → 新建/导入）。没登记时 DPanel 会返回 `{"code":500,"error":"...commonDataNotFoundOrDeleted..."}`，脚本会识别出来并给出迁移指引，退出码 `1`。
- 依赖命令：`timeout` `sed` `awk` `grep`（busybox / coreutils 都行）。**不再需要 `curl`、`flock`**。不在 dpanel 容器内时额外需要 `docker`。

参数与环境变量见 [参数文档](parameters.md#全部命令行参数)。

## 3. 一轮都发生了什么

```
1. 解析参数
2. 兼容检查：旧 flag / 旧环境变量命中 → 中止并给出迁移方式（退出码 3）
   --compat <版本> 声明「只验证到某版本」→ 含更新的破坏性变更就硬停
3. 依赖检查：timeout / sed / awk / grep；不在 dpanel 容器内时还要 docker
   然后调 DPanel CLI（dp_cli version）确认它确实可用
4. 按模式转交更新：
     容器          → container:upgrade（先不带 --upgrade 只检查）
     Compose 项目  → compose:deploy --name <项目名> --pull-image dpanel
5. 报结果（OK / ERR / WARN / DRY）
6. 写 lastver（跨版本提示用的「这个目标见过当前版本」记录）
7. 退出
```

两个顺序是刻意的：

- **兼容检查排在依赖检查之前** —— 调用方式已经失效时要先看到迁移说明，而不是先被一句「找不到 docker / 找不到 DPanel CLI」引向无关的排查方向。
- **跨版本 `WARN` 在依赖检查之前打印，但 `lastver` 在依赖检查之后才写** —— 依赖缺失那一轮不算「用户已知悉」，下次仍会提示。

## 4. 容器模式（`--container`）的完整流程

1. `container:upgrade --name <容器> --docker-env local`（**不带** `--upgrade`）= **只检查**。DPanel 自己比对远端与本地 digest，返回 JSON：

   ```json
   {"upgrade":true,"digest":"sha256:a5c10db1...","digestLocal":["ghcr.1ms.run/yetone/magpie@sha256:d9d64cc1..."],"error":"","message":"","status":"upgrade"}
   ```

2. `upgrade` **不是** `true` → 就是「已是最新」。脚本打 `OK 容器 <名> 已是最新（DPanel 报告 status=latest）`，退出码 `0`，**容器一点没动**。

   ```text
   [2026-11-03 16:38:08] OK 容器 myapp 已是最新（DPanel 报告 status=latest）
       → OK: container myapp is already up to date (DPanel reports status=latest)
   ```

3. `--dry-run` → 打 `发现新版本（远端 digest=sha256:...）` + `DRY 只检查不动手，本轮不升级`，退出码 `0`。

   ```text
   [2026-11-03 16:38:08] 发现新版本（远端 digest=sha256:a5c10db1...）
   [2026-11-03 16:38:08] DRY 只检查不动手，本轮不升级
       → DRY: check only, no action taken; this round does not upgrade
   ```

4. 剩余时间不足（`< DP_MIN_UPGRADE`，默认 90 秒）→ **不动手**，退出码 `1`：

   ```text
   [2026-11-03 16:38:08] WARN 剩余时间不足（40s < 90s），本轮不启动升级，容器保持原样
   [2026-11-03 16:38:08]      下一轮计划任务会重新检查；也可以把 T_HARD 或计划任务的超时调大
       → WARN: not enough time left (40s < 90s); the upgrade is not started this round and the container is left as is
       →      the next scheduled task will check again; you can also raise T_HARD or the timeout of the scheduled task
   ```

5. 真升级加 `--upgrade`：`container:upgrade --name <容器> --upgrade --docker-env local`。成功返回 `{"containerId":"..."}`，脚本打 `OK DPanel 已完成升级（containerId=...）`，退出码 `0`。

6. **回滚点 = DPanel 生成的备份容器**，名字形如 `<容器名>-bak-<时间戳>`（例如 `myapp-bak-20261103163808`）：它跑着升级前的镜像、处于 Exited 状态。要回滚就把它改回来（DPanel 网页里能直接看到这个备份容器）。

7. **升级失败时 DPanel 自己回滚**（实测：镜像坏掉时容器保持旧镜像，并留下备份容器）。脚本报错退出码 `1`，日志里带 DPanel 的错误文本。

> 这是 v2.0.0 与 v1.x **最大的不同**：回滚点不再是 `:prev` 镜像标签，而是 DPanel 的备份容器。

## 5. Compose 模式（`--compose`）的完整流程

1. **只能部署，没有「只检查」**：DPanel 的 `compose:deploy` 就是部署动作。
2. **`--dry-run` 在 Compose 模式下什么都不做**，只如实说明，退出码 `0`：

   ```text
   [2026-11-03 16:38:08] DRY Compose 模式没有「只检查」能力（DPanel 的 compose:deploy 会直接部署）
   [2026-11-03 16:38:08]     本轮未执行部署；要检查容器有没有新版本请用 --container 模式
       → DRY: Compose mode has no "check only" capability (DPanel's compose:deploy deploys directly)
       →     nothing was deployed this round; to check whether a container has a new version, use --container mode
   ```

   要预演只能靠容器模式，或者先在测试项目上跑一遍。
3. 真部署：`compose:deploy --name <项目名> --pull-image dpanel --docker-env local`。
4. 剩余时间不足（`< DP_MIN_UPGRADE`）→ 不部署，退出码 `1`：`WARN 剩余时间不足（40s < 90s），本轮不部署，项目保持原样`。
5. 成功 → 打 `OK DPanel 已部署 Compose 项目 <项目名>`，退出码 `0`。

### 为什么必须显式 `--pull-image dpanel`

`--pull-image` 有 `dpanel` / `command` 两个取值，**默认是 `command`**。实测 `command` 那条路**不会去拉新镜像**（已是最新的标签不会重新回源），结果就是「部署成功但版本没变」。所以脚本显式传 `--pull-image dpanel`，让 DPanel 用自己的拉取逻辑先拉每个服务的镜像，再部署。

### 成功与失败都藏在 JSON 里

- 成功时 DPanel 返回 `{"name":"<项目名>"}` —— **注意：成功时没有 `code` 字段**。
- 失败可能是 `{"code":500,...,"error":"..."}`，而且 **CLI 退出码仍然是 `0`** —— 退出码不可信，**成败必须解析 JSON**。
- 脚本判定失败的条件是「`code` ≥ 400，或 `status=failed`，或 `error` 字段非空」，**不是**「`code` 不等于 200」。写成后者会把「成功但没 `code`」误判成失败。
- 项目没在 DPanel 里登记 → `commonDataNotFoundOrDeleted` → 脚本给迁移指引并退出 `1`：

  ```text
  [2026-11-03 16:38:08] ERR DPanel 里没有登记名为 myapp 的 Compose 项目
  [2026-11-03 16:38:08]     compose:deploy 只能操作 DPanel「Compose」页面里登记过的项目
  [2026-11-03 16:38:08]     处理方式二选一：
  [2026-11-03 16:38:08]       1) 在 DPanel 网页里新建 Compose 项目，名称填 myapp（指向它的 docker-compose.yaml）
  [2026-11-03 16:38:08]       2) 改用容器模式：--container <该项目里的容器名>
  [2026-11-03 16:38:08]     项目未做任何改动
      → ERR: DPanel has no Compose project registered under the name myapp
      →      compose:deploy can only act on projects registered on DPanel's "Compose" page
      →      two ways out:
      →        1) create a Compose project in the DPanel web UI named myapp (pointing at its docker-compose.yaml)
      →        2) switch to container mode: --container <a container name of that project>
      →      the project was left untouched
  ```

## 6. 什么情况会跳过 / 不动手

这些都不是故障，是脚本（或 DPanel）主动不动手。日志里会写明具体原因。

| 情况 | 结果 |
|---|---|
| 容器模式：DPanel 报告 `status=latest`（`upgrade` 不是 `true`） | 打 `OK 容器 <名> 已是最新…`，退出码 `0`，容器一点没动 |
| `--dry-run`（容器模式） | 只检查并打印发现的新版本，退出码 `0`，不升级 |
| `--dry-run`（Compose 模式） | **什么都不做**，退出码 `0`（`compose:deploy` 没有「只检查」能力） |
| 剩余时间不足（`< DP_MIN_UPGRADE`，默认 90 秒） | 不打乱干，退出码 `1`，目标保持原样 |
| Compose 项目未在 DPanel 登记 | 打 `ERR DPanel 里没有登记名为 <名> 的 Compose 项目` + 迁移指引，退出码 `1` |
| 旧参数 / 旧环境变量命中 `BREAKING_TABLE` | 立即中止，退出码 `3`，什么都没改，日志里有新写法 |
| 依赖命令缺失（`timeout` `sed` `awk` `grep`，或不在 dpanel 容器内时缺 `docker`） | 打 `ERR 缺少依赖命令：…`，退出码 `1` |

旧参数：`--compose-dir`、`--state-dir`、`--bad-ttl-days`、`--pull-retries`；旧环境变量见 [参数文档](parameters.md#全部环境变量)。

## 7. 保护不了什么（重要）

### Compose 模式没有「只检查」

`compose:deploy` 就是部署动作，DPanel 没给 Compose 提供「只查不部署」的接口。所以 Compose 模式下 `--dry-run` 什么都不做，也没法提前预演；要预演只能靠容器模式，或先在测试项目上跑。

### Compose 模式不生成备份容器、不维护 `:prev`

DPanel 的 compose 部署没有备份机制，脚本也不再自己打 `:prev` 标签。所以：

- **回滚只能靠本地旧镜像**；
- **Compose 模式无法提前知道「有没有新版本」**：脚本不做镜像 digest 比对（那是 v1.x 干的活），它就是把部署交给 DPanel，由 DPanel 决定要不要重建。日志里不会有「已是最新」这种判断（除非 DPanel 自己在输出里说）。

Compose 模式的手工回滚：

```sh
# 旧镜像还在本地时（先 docker images 找到旧镜像 ID）
docker tag <旧镜像ID> <镜像仓库>:latest
docker compose up -d --force-recreate
```

容器模式则相反：DPanel 会留下 `<容器名>-bak-<时间戳>` 备份容器。DPanel 的 `--disable-bak` 我们**没有传**，默认就是备份。

### 容器健康与业务正确，脚本不再自己判定

v1.x 会自己观察容器是否 healthcheck 通过、启动后是否还在跑。v2.0.0 起这件事交给 DPanel：脚本只报 DPanel 说的结果。

### 数据不会被回滚

回滚只恢复**容器和镜像**。新版本程序已经对数据卷 / 数据库做过的迁移、写入、schema 变更，**不会**因为回滚而撤销。

> 跑数据库、跑有状态服务的容器，请务必另有备份。脚本和 DPanel 能保证「容器回到旧镜像」，保证不了「数据回到旧状态」。

### 只处理「一个新版本」

如果上游一次性跳了好几个版本，本轮只会到最新那个，不会逐个过渡。跨大版本的升级（比如数据库 schema 要求逐版迁移）需要你自己安排。

### 镜像从哪来，脚本不管

脚本**不碰 Registry**：镜像源由 Docker daemon / DPanel 与你自己的配置决定。所以「多个 GitHub 加速站并行竞速」这类机制在 v2.0.0 架构下不再需要，也不再实施。

## 8. 失败现场长什么样

### 错误行同时在 stdout 和真正的 stderr

计划任务（DPanel）在任务**失败**时只保留 stderr、丢弃 stdout。所以 `ERR` / `CRITICAL` 行（以及紧随其后的缩进补充行）会**同时**写两份：完整日志在 stdout，失败原因额外写一份到真正的 stderr。这样计划任务里就不会只剩一句干巴巴的 `exit status 1`，**日志里一定有原因**（这也是排查失败的第一手材料）。

DPanel 的原始错误文本会被**透传**进日志，脚本不改写它。详见 [参数文档](parameters.md#失败原因写到哪里)。

### 退出码

| 退出码 | 现场 |
|---|---|
| `0` | 成功（含「已是最新」与 `--dry-run`） |
| `1` | 失败：DPanel 报错、项目未登记、剩余预算不足、依赖缺失、参数错误。目标保持原样 |
| `2` | 保留。v2.0.0 目前不产生（回滚由 DPanel 负责，脚本不感知） |
| `3` | **破坏性变更**：你的调用方式已失效。脚本在动手之前就停下，什么都没改，按日志里的迁移方式改命令即可 |
| `130` | 被 Ctrl-C（SIGINT）中断 |
| `143` | 被 `timeout` / SIGTERM 杀掉（DPanel 计划任务超时常见） |

## 9. 与 v1.x 的差别

| 方面 | v1.x | v2.0.0 |
|---|---|---|
| 谁拉镜像 | 脚本自己走 Docker Engine API 拉，还盯进度字节数、判卡死、重试 | DPanel、Docker daemon（脚本不碰 Registry） |
| 谁重建容器 | 脚本自己按声明式配置重建，还要逐项校验规格 | DPanel 的 `container:upgrade` |
| 谁重建 Compose 项目 | 脚本自己 `docker compose up -d --force-recreate` | DPanel 的 `compose:deploy` |
| 回滚点 | `<镜像仓库>:prev` 标签（只留 1 份） | DPanel 的备份容器 `<容器名>-bak-<时间戳>`（容器模式） |
| 健康门禁 | 脚本自己判断（healthcheck / 观察 30 秒） | DPanel 的升级流程负责，脚本不再判定 |
| 坏版本钉住 | `<镜像仓库>:bad`，默认 7 天 | 取消 |
| 失败原因 | stdout + 真正的 stderr | 不变（stdout + 真正的 stderr） |
| 事务目录 | `--state-dir` / `STATE_ROOT`，保留回滚现场 | 取消 |
| 互斥锁 | 已移除（并发靠 DPanel 计划任务） | 不变：脚本内部不加锁 |
| 拉取控制参数 | `--pull-retries`、`PULL_RETRIES`、`DIGEST_RETRIES`、`T_STALL`、`T_STALL_FINISH` 等 | 全部作废（拉取由 DPanel 负责） |
| 跨版本提示 | `COMPAT_ROOT` 下的 `lastver` | 不变 |

作废的参数与环境变量（命中即中止，退出码 `3`）：

- 参数：`--compose-dir`、`--state-dir`、`--bad-ttl-days`、`--pull-retries`。
- 环境变量：`STATE_ROOT`、`BAD_TTL_DAYS`、`PULL_RETRIES`、`DIGEST_RETRIES`、`DIGEST_RETRY_WAIT`、`T_STALL`、`T_STALL_FINISH`、`T_PULL_MAX`、`T_UP`、`T_HEALTH`、`HEALTH_TRIES`、`T_ROLLBACK`、`PLAIN_BOOT`、`COMPOSE_DIR`、`COMPOSE_BASE`。
- 例外：`T_INSPECT` 仍被接受，等价于 `DP_T_CHECK`。

另外，v2.0.0 **不再产生** `<镜像仓库>:prev` 标签和 `/tmp/.container-autoupdate/compose-*` 事务目录；升级后可以手动清掉（排查脚本 `scripts/ct-stale-lock-check.sh` 会把它们列出来）。

迁移与版本策略见 [README](../README.md#版本与升级)。
