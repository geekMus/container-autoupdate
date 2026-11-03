# 工作方式与安全边界

> 语言：[中文](how-it-works.md) | [English](how-it-works.en.md)

> 这一页解释脚本**怎么做**、**什么情况会不动手**、**哪些事它保护不了**。用之前值得花三分钟读一遍。

## 1. 一句话说清它做什么

v2.0.0 起，脚本**不再自己拉镜像、不再自己重建容器**：它只做三件事 ——

1. **判断这个目标该不该更新**（容器模式 = 问 DPanel；Compose 模式 = 拉取本身就是判断）；
2. **把更新动作交出去执行**；
3. **把结果如实报出来**（成功 / 失败 / 无需更新）。

「交出去」分两条路（v2.1.0 起 Compose 走第二条，不再交给 DPanel）：

| 更新目标 | 交给谁 | 脚本实际执行 |
|---|---|---|
| 容器（`--container <容器名>`） | DPanel | `container:upgrade`（先检查，确实有新版本才加 `--upgrade`） |
| Compose 项目（`--compose <项目名>`） | docker compose 自己 | `docker compose pull` + `docker compose up -d` |

为什么这么分：

- 重建一个容器要**准确复刻**网络、挂载（含匿名卷真实名字）、资源限制、重启策略、Capabilities……漏一处就是生产事故。v1.x 为此写了上千行，仍出过「拉取卡死被误判」「失败原因打两遍」这类问题。DPanel 本来就有成熟实现，而且**升级失败它会自行回滚**。
- Compose 项目不用脚本重建：compose 自己就把「这个项目有哪些容器、用哪个 compose 文件、工作目录在哪」写在容器标签上，`pull` + `up -d` 就是它的标准做法。所以**项目不需要先在 DPanel 网页里登记**，也不用管 DPanel `compose:deploy` 的 `--pull-image` 默认值那个坑。
- 回滚点不再由脚本打 `<镜像仓库>:prev` 标签自己维护，也就不会出现「回滚点被清理逻辑误删」这类问题。
- 脚本因此从 1700+ 行降到几百行：逻辑面小，剩下的每一条都能一眼看懂、一眼验证。

## 2. 前置条件

- **容器模式需要 DPanel**：更新动作靠 DPanel CLI（`container:upgrade`）。推荐**在 DPanel 容器里跑**（DPanel 的「计划任务」默认就在 `dpanel` 容器内执行），脚本直接执行 `/app/server/dpanel`；在别处跑时脚本改用 `docker exec <dpanel 容器> /app/server/dpanel ...`，容器名用 `--dpanel-container`（默认 `dpanel`）、路径用 `--dpanel-bin` 指定。**不在 dpanel 容器内跑时，额外需要 `docker` 命令。**
- **Compose 模式不需要 DPanel**：它要的是 `docker` 命令和 **Compose v2 插件**（`docker compose`，不是 `docker-compose`），项目**也不需要先在 DPanel 里登记**。项目目录与 compose 文件默认从容器标签反查，反查不到时才用 `--compose-dir` / `COMPOSE_DIR` 兜底。
- 依赖命令：`timeout` `sed` `awk` `grep`（busybox / coreutils 都行）。**不再需要 `curl`、`flock`**。
- 脚本会先验证 `docker version` 连得上，Compose 模式再验证 `docker compose version` 能用 —— 缺哪一环就报哪一环，不会被引到无关的排查方向。

参数与环境变量见 [参数文档](parameters.md#全部命令行参数)。

## 3. 一轮都发生了什么

```
1. 解析参数
2. 兼容检查：旧 flag / 旧环境变量命中 → 中止并给出迁移方式（退出码 3）
   --compat <版本> 声明「只验证到某版本」→ 含更新的破坏性变更就硬停
3. 跨版本 WARN：这个目标上次跑的版本更早、中间又有 behavior 级变更 → 提示后照常执行
4. 依赖检查：
     timeout / sed / awk / grep；
     Compose 模式（或不在 dpanel 容器内）要 docker，Compose 模式还要 docker compose v2 插件；
     容器模式再探一次 DPanel CLI（dp_cli version）
5. 写 lastver（「这个目标见过当前版本」的记录）
6. 按模式执行更新：
     容器          → container:upgrade（先不带 --upgrade 只检查）
     Compose 项目  → docker compose pull + docker compose up -d
7. 报结果（OK / ERR / WARN / DRY）
8. 退出
```

三个顺序是刻意的：

- **兼容检查排在依赖检查之前** —— 调用方式已经失效时要先看到迁移说明，而不是先被一句「找不到 docker / 找不到 DPanel CLI」引向无关的排查方向。
- **跨版本 `WARN` 在依赖检查之前打印，但 `lastver` 在依赖检查之后才写** —— 依赖缺失那一轮不算「用户已知悉」，下次仍会提示。
- **`lastver` 写在真正执行更新动作之前** —— 只要这一轮跑到了更新逻辑，就说明提示已经送到用户眼前了；更新本身成功与否不影响这一点。

主流程见 `container-autoupdate.sh` 第 918–971 行。

## 4. 容器模式（`--container`）的完整流程

实现见 `container_update()`（`container-autoupdate.sh` 第 639–693 行）。分支开头先打一行 `MODE container 容器=<容器名>`。

1. `container:upgrade --name <容器> --docker-env local`（**不带** `--upgrade`）= **只检查**。DPanel 自己比对远端与本地 digest，返回 JSON：

   ```json
   {"upgrade":true,"digest":"sha256:a5c10db1...","digestLocal":["ghcr.1ms.run/yetone/magpie@sha256:d9d64cc1..."],"error":"","message":"","status":"upgrade"}
   ```

2. `upgrade` **不是** `true` → 就是「已是最新」。脚本打 `OK 容器 <名> 已是最新（DPanel 报告 status=latest）`，退出码 `0`，**容器一点没动**。

   ```text
   [2026-11-03 16:38:08] OK 容器 myapp 已是最新（DPanel 报告 status=latest）
       → OK: container myapp is already up to date (DPanel reports status=latest)
   ```

3. `--dry-run` → 真问一次 DPanel；发现有新版本就只打印，不升级，退出码 `0`：

   ```text
   [2026-11-03 16:38:08] 发现新版本（远端 digest=sha256:a5c10db1...）
   [2026-11-03 16:38:08] DRY 只检查不动手，本轮不升级
       → new version found (remote digest=sha256:a5c10db1...)
       → DRY: check only, no action taken; this round does not upgrade
   ```

4. 剩余时间不足（`< DP_MIN_UPGRADE`，默认 90 秒）→ **不动手**，退出码 `1`：

   ```text
   [2026-11-03 16:38:08] WARN 剩余时间不足（40s < 90s），本轮不启动升级，容器保持原样
   [2026-11-03 16:38:08]      下一轮计划任务会重新检查；也可以把 T_HARD 或计划任务的超时调大
       → WARN: not enough time left (40s < 90s); the upgrade is not started this round and the container is left as is
       →      the next scheduled task will check again; you can also raise T_HARD or the timeout of the scheduled task
   ```

5. 真升级加 `--upgrade`：`container:upgrade --name <容器> --upgrade --docker-env local`。脚本先打一行等待上限，成功返回 `{"containerId":"..."}`，脚本打 `OK DPanel 已完成升级（containerId=...）`，退出码 `0`：

   ```text
   [2026-11-03 16:38:08] 交给 DPanel 升级（等待上限 420s；新容器起不来时 DPanel 会自行回滚）
   [2026-11-03 16:38:08] OK DPanel 已完成升级（containerId=3f2a9c1b7d5e）
       → handing the upgrade to DPanel (waiting at most 420s; when the new container will not start, DPanel rolls back by itself)
       → OK: DPanel finished the upgrade (containerId=3f2a9c1b7d5e)
   ```

6. **回滚点 = DPanel 生成的备份容器**，名字形如 `<容器名>-bak-<时间戳>`（例如 `myapp-bak-20261103163808`）：它跑着升级前的镜像、处于 Exited 状态。要回滚就把它改回来（DPanel 网页里能直接看到这个备份容器）：

   ```sh
   docker stop myapp && docker rm myapp
   docker rename myapp-bak-20261103163808 myapp
   docker start myapp
   ```

7. **升级失败时 DPanel 自己回滚**（实测：镜像坏掉时容器保持旧镜像，并留下备份容器）。脚本报错退出码 `1`，日志里带 DPanel 的原始错误文本：

   ```text
   [2026-11-03 16:38:08] ERR DPanel 升级失败：镜像拉取失败
   [2026-11-03 16:38:08]     容器保持原样；DPanel 若已重建过会自行回滚（备份容器 <容器名>-bak-<时间戳>）
       → ERR: the DPanel upgrade failed: the image pull failed
       →      the container is left as is; if DPanel had already rebuilt it, it rolls back by itself (backup container <container name>-bak-<timestamp>)
   ```

> 容器模式与 v1.x **最大的不同**：回滚点不再是 `:prev` 镜像标签，而是 DPanel 的备份容器。脚本**从不传** `--disable-bak`，所以「留备份」是默认行为。

### DPanel 的成败只能解析 JSON 判

DPanel CLI 的**退出码不可信**：实测「容器不存在」「镜像清单读不到」这类失败，退出码仍然是 `0`。脚本的判定条件是 **`code` ≥ 400，或 `status=failed`，或 `error` 字段非空** —— 不是「`code` 不等于 200」。反过来，成功时（例如 `{"containerId":"..."}`）**根本没有 `code` 字段**，把它当失败信号 就会把一次成功误判成失败。

另外两条取结果的规矩：调用 DPanel 时**不加 `-q` / `--quiet`**（它会把结果 JSON 一起吞掉），取结果用「stdout 里**最后一个**以 `{` 开头的行」；取 `error` 文本时**不按逗号截断**（DPanel 的错误文本里就有逗号，截断后真实原因就丢了）。

## 5. Compose 模式（`--compose`）的完整流程

实现见 `compose_update()`（`container-autoupdate.sh` 第 808–916 行）与 `compose_locate()`（第 747–775 行）。分支开头先打一行 `MODE compose 项目=<项目名>`。

1. **认出这个项目**：先用容器标签反查 —— `docker ps -a --filter label=com.docker.compose.project=<项目名>` 取第一个容器，再 `docker inspect` 读三个标签：`com.docker.compose.project.working_dir`（目录）、`com.docker.compose.project.config_files`（compose 文件）、`com.docker.compose.project.environment_file`（env 文件）。**反查不到时**（这个项目连一个容器都没有）才用 `--compose-dir` / `COMPOSE_DIR` 兜底；两者都没有 → 退出码 `1`：

   ```text
   [2026-11-03 16:38:08] ERR 找不到 Compose 项目 myapp 的项目目录
   [2026-11-03 16:38:08]     当前 Docker 里没有带「myapp」这个 compose 项目标签的容器，反查不到
   [2026-11-03 16:38:08]     处理方式二选一：
   [2026-11-03 16:38:08]       1) 用 --compose-dir <路径> 指定 compose 文件所在目录
   [2026-11-03 16:38:08]       2) 确认项目名写法；项目还没部署过就先手动 compose up 一次
       → ERR: cannot find the project directory of Compose project myapp
       →      no container in the current Docker carries the "myapp" compose project label, so it cannot be looked up backwards
       →      two ways out:
       →        1) name the directory holding the compose file with --compose-dir <path>
       →        2) check how the project name is written; if the project has never been deployed, run compose up once by hand
   ```

   反查到了目录但它不存在 → `ERR Compose 项目目录不存在：<路径>`，退出码 `1`。

2. **列出这个项目涉及的镜像**：`docker compose config --images`，先打 `    目录=<目录>`（有 compose 文件时再打 `    文件=<文件>`），然后逐行打 `    镜像: <镜像引用>`。读不出清单时只打一条警告继续走，不中止。

   ```text
   [2026-11-03 16:38:08]     目录=/opt/myapp
   [2026-11-03 16:38:08]     文件=/opt/myapp/compose.yaml
   [2026-11-03 16:38:08]     镜像: ghcr.1ms.run/yetone/magpie:latest
   [2026-11-03 16:38:08] WARN docker compose config 没能读出这个项目的镜像清单（退出码 1），继续按流程走
       → WARN: docker compose config could not read this project's image list (exit code 1); carrying on with the flow
   ```

3. **`--dry-run`：只列镜像，然后退出 `0`**，本轮不拉取、不部署：

   ```text
   [2026-11-03 16:38:08] DRY 只检查不动手：上面是这个项目涉及的镜像，本轮不拉取、不部署
   [2026-11-03 16:38:08]     要真正更新就去掉 --dry-run（拉取本身就是「有没有新版本」的判断）
       → DRY: check only, no action: the lines above are the images this project involves; nothing is pulled or deployed this round
       →     to actually update, drop --dry-run (the pull itself is the "is there a new version" decision)
   ```

4. **预算门**：剩余时间 `< DP_MIN_UPGRADE`（默认 90 秒）→ 不部署，退出码 `1`：

   ```text
   [2026-11-03 16:38:08] WARN 剩余时间不足（40s < 90s），本轮不部署，项目保持原样
       → WARN: not enough time left (40s < 90s); nothing is deployed this round and the project is left as is
   ```

5. **记录快照**：把「容器名 → 镜像 id」记下来（`docker ps -a` + `docker inspect`），部署后拿它对比。键必须是**容器名**而不是容器 ID —— `up -d` 重建容器后 ID 会变，用 ID 当键会把每个被重建的容器都误判成「新建」，永远报不出「已重建」（N1 真机实测踩到）。

6. **拉取**：`docker compose pull`，等待上限 `DP_T_PULL`（默认 420 秒）。失败时**不部署**，项目保持原样，退出码 `1`，并把 compose 自己最后 5 行原话贴进日志：

   ```text
   [2026-11-03 16:38:08] 拉取镜像（docker compose pull，等待上限 420s）
   [2026-11-03 16:38:08] ERR 拉取失败（docker compose pull 退出码 1），本轮不部署，项目保持原样
       → pulling images (docker compose pull, waiting at most 420s)
       → ERR: the pull failed (docker compose pull exited with 1); nothing is deployed this round and the project is left as is
   ```

   进不去项目目录是单独一种失败：`ERR 无法进入 Compose 项目目录：<路径>`。

7. **就地重新部署**：`docker compose up -d`，等待上限 `DP_T_UP`（默认 180 秒）。**绝不加 `--remove-orphans`**（它会删掉不在当前 compose 文件里的容器，属于数据事故）。失败时退出码 `1`：

   ```text
   [2026-11-03 16:38:08] 就地重新部署（docker compose up -d，等待上限 180s）
   [2026-11-03 16:38:08] ERR 重新部署失败（docker compose up -d 退出码 1）
   [2026-11-03 16:38:08]     compose 文件与容器定义都没被脚本改过，可以直接再跑一轮
       → redeploying in place (docker compose up -d, waiting at most 180s)
       → ERR: the redeploy failed (docker compose up -d exited with 1)
       →      neither the compose file nor the container definitions were changed by the script; you can run another round right away
   ```

8. **如实报告**：拿第 5 步的快照对比，三种情况分开说 —— **已重建**（镜像 id 变了）、**新建**（部署前没有这个容器：首次部署，或 compose 文件里新加的服务）、以及什么都没变：

   ```text
   [2026-11-03 16:38:08]     已重建：myapp-web（3f2a9c1b7d5e → 8c1d4e6a9f02）
   [2026-11-03 16:38:08]     新建：myapp-worker（8c1d4e6a9f02）
   [2026-11-03 16:38:08] OK Compose 项目 myapp 已重新部署（1/3 个容器换了镜像，1 个新建）
       →      rebuilt: myapp-web (3f2a9c1b7d5e → 8c1d4e6a9f02)
       →      created: myapp-worker (8c1d4e6a9f02)
       → OK: Compose project myapp was redeployed (1/3 containers switched images, 1 created)
   ```

   汇总行四选一：

   | 情况 | 汇总行 |
   |---|---|
   | 有容器换了镜像，也有新建 | `OK Compose 项目 <名> 已重新部署（N/M 个容器换了镜像，K 个新建）` |
   | 只有容器换了镜像 | `OK Compose 项目 <名> 已重新部署（N/M 个容器换了镜像）` |
   | 只有新建 | `OK Compose 项目 <名> 已部署（K 个容器新建）` |
   | 什么都没变 | `OK Compose 项目 <名> 已是最新（拉取后没有容器需要重建）` |

   最后查一遍**有没有容器没在运行**（项目里一个容器都没有时跳过这一查）：

   ```text
   [2026-11-03 16:38:08] ERR 有容器没在运行（2/3 running）：
   [2026-11-03 16:38:08]     myapp-worker exited
   [2026-11-03 16:38:08]     compose 文件没被改过；用 docker compose logs <服务名> 看具体原因
       → ERR: some containers are not running (2/3 running):
       →      myapp-worker exited
       →      the compose file was not changed; use docker compose logs <service name> to see the reason
   ```

   有容器没在运行 → 退出码 `1`；全部在运行 → 打一行 `    运行状态：3/3`，退出码 `0`。

### 为什么 Compose 模式不需要先在 DPanel 里登记

DPanel 的 `compose:deploy` 只认它网页里登记过的项目（v2.0.0 走的就是那条路，所以那时必须先「新建 / 导入」一次）。现在这条路上没有 DPanel 参与：compose 自己知道项目有哪些容器、用哪个文件，脚本只是在该目录里跑 `docker compose`。

### 拉取本身就是「有没有新版本」的判断

Compose 模式**没有「只检查」这一步**：脚本不做镜像 digest 比对，`docker compose pull` 有没有真的拉下新东西，就是本轮「要不要重建」的依据；没有新版本时它是一次很快的空操作。所以这类日志里不会出现「发现了新版本」这种预言——那只有容器模式（DPanel 真去查一次）才有。

### 只用 compose 自己的 pull / up -d

- 不手工 `docker tag`、不手工 `docker create`、**不删任何东西**；重建交给 compose。
- compose 参数一律走环境变量 `COMPOSE_PROJECT_NAME` / `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` / `COMPOSE_ENV_FILES`，不拼进命令行 —— 路径含空格时 compose 会打印 Usage 却返回 `0`（静默出错）。
- 保留原有的项目名、compose 文件与 env 文件；工作目录就是反查到的那个目录（compose 文件里的相对路径靠它解析）。

## 6. 什么情况会跳过 / 不动手

这些都不是故障，是脚本（或 DPanel）主动不动手。日志里会写明具体原因。

| 情况 | 结果 |
|---|---|
| 容器模式：DPanel 报告 `status=latest`（`upgrade` 不是 `true`） | 打 `OK 容器 <名> 已是最新…`，退出码 `0`，容器一点没动 |
| 容器模式 `--dry-run` | 真问 DPanel 一次，只打印发现的新版本，退出码 `0`，不升级 |
| Compose 模式 `--dry-run` | 只列出项目涉及的镜像，退出码 `0`，不拉取也不部署 |
| 剩余时间不足（`< DP_MIN_UPGRADE`，默认 90 秒） | 不动手，退出码 `1`，目标保持原样（容器 / 项目各有各的文案） |
| Compose 项目反查不到目录，也没给 `--compose-dir` | 打 `ERR 找不到 Compose 项目 <名> 的项目目录` + 两条处理方式，退出码 `1` |
| Compose 项目目录不存在 | 打 `ERR Compose 项目目录不存在：<路径>`，退出码 `1` |
| 有容器没在运行（Compose 模式部署之后） | 逐条点名 + `ERR 有容器没在运行（R/M running）`，退出码 `1` |
| 旧参数 / 旧环境变量命中 `BREAKING_TABLE` | 立即中止，退出码 `3`，什么都没改，日志里有新写法 |
| 依赖命令缺失（`timeout` `sed` `awk` `grep`） | 打 `ERR 缺少依赖命令：…`，退出码 `1` |
| `docker` 连不上 | 打 `ERR 无法连接 Docker（DOCKER_HOST=…）`，退出码 `1` |
| Compose 模式缺 Compose v2 插件 | 打 `ERR 无法执行 docker compose（缺 compose 插件？）`，退出码 `1` |
| 容器模式探不到 DPanel CLI（`dp_cli version` 没输出） | 打 `ERR 无法调用 DPanel CLI（…）`，退出码 `1` |
| `--compose` 与 `--container` 都给 / 都没给 | 打 `ERR 必须且只能指定一个目标…`，退出码 `1` |

旧参数：`--state-dir`、`--bad-ttl-days`、`--pull-retries`（`--compose-dir` **已恢复可用**）；旧环境变量见 [参数文档](parameters.md#全部环境变量)。

## 7. 保护不了什么（重要）

### Compose 模式没有「只检查有没有新版本」的能力

这条路上脚本不查 digest，**拉取本身就是判断**。所以 `--dry-run` 只能列出这个项目涉及哪些镜像，不拉取、不部署，也就不会告诉你「有没有新版本」。想提前看有没有新版本，只能靠容器模式（`--container`，DPanel 真去查一次），或者先在测试项目上跑一轮。

### Compose 模式没有备份容器，也不维护 `:prev`

这条路上 compose 不生成备份容器，脚本也不再自己打 `:prev` 标签。回滚只能靠「旧镜像还在本地」这一点 —— 旧镜像 id 可以从上一轮日志的 `已重建：<名>（旧12位 → 新12位）` 里看到，或者去 `docker images` 里找：

```sh
# 旧镜像还在本地时
docker tag <旧镜像ID> <镜像仓库>:latest
docker compose up -d --force-recreate
```

容器模式相反：DPanel 会留下 `<容器名>-bak-<时间戳>` 备份容器（网页里可直接恢复）。DPanel 的 `--disable-bak` 我们**没有传**，默认就是备份。

### 坏镜像由谁挡

脚本**不判断镜像里装的是不是坏版本**。容器模式靠 DPanel（新容器起不来时它会自行回滚）；Compose 模式靠「失败就不部署」加上「起不来的容器会被点名」——脚本只把事实报出来。

### 健康与业务正确性不归脚本管

脚本只保证两件事：**compose 命令成功**，以及**容器在运行**。它不跑 healthcheck、不观察若干秒、不验证服务是否真的可用。Compose 模式最后那句 `运行状态：R/M` 只说明有 R 个容器处于 running，不等于服务可用。

### 数据不会被回滚

回滚只恢复**容器和镜像**。新版本程序已经对数据卷 / 数据库做过的迁移、写入、schema 变更，**不会**因为回滚而撤销。

> 跑数据库、跑有状态服务的容器，请务必另有备份。脚本和 DPanel 能保证「容器回到旧镜像」，保证不了「数据回到旧状态」。

### 只处理「一个新版本」

如果上游一次性跳了好几个版本，本轮只会到最新那个，不会逐个过渡。跨大版本的升级（比如数据库 schema 要求逐版迁移）需要你自己安排。

### 镜像从哪来，脚本不管

脚本**不碰 Registry**：镜像拉取交给 docker / daemon 与镜像源，用的是你自己配置的那套（Docker 的 registry-mirror、DPanel 的设置）。所以「多个 GitHub 加速站并行竞速」这类机制**不需要了，也没有实施**：哪个源快、能不能拉通，是 docker 的事，脚本对此没有任何控制。

（对比：计划任务里下载「脚本自身」的那段用的是「第一个地址失败才试第二个」，也不是并行竞速——一个不到 50KB 的文件，串行试两次已经够快。）

## 8. 失败现场长什么样

### 错误行同时在 stdout 和真正的 stderr

计划任务（DPanel）在任务**失败**时只保留 stderr、丢弃 stdout。所以 `ERR` / `CRITICAL` 行（以及紧随其后的缩进补充行）会**同时**写两份：完整日志在 stdout，失败原因额外写一份到真正的 stderr。这样计划任务里就不会只剩一句干巴巴的 `exit status 1`，**日志里一定有原因**（这也是排查失败的第一手材料）。

报错时脚本还会把更新执行者自己说的话贴出来：容器模式是 DPanel 的原始错误文本（**透传**，脚本不改写它），Compose 模式是 compose 输出的最后 5 行原话。详见 [参数文档](parameters.md#失败原因写到哪里)。

### 退出码

| 退出码 | 现场 |
|---|---|
| `0` | 成功（含「已是最新」与两种模式的 `--dry-run`） |
| `1` | 失败：DPanel 报错、找不到 / 进不去 Compose 项目目录、拉取或部署失败、有容器没在运行、剩余预算不足、依赖缺失、参数错误。目标保持原样 |
| `2` | 保留。当前版本不产生：容器回滚由 DPanel 负责；Compose 模式失败时不部署，不会留下半新半旧的项目 |
| `3` | **破坏性变更**：你的调用方式已失效。脚本在动手之前就停下，什么都没改，按日志里的迁移方式改命令即可 |
| `130` | 被 Ctrl-C（SIGINT）中断 |
| `143` | 被 `timeout` / SIGTERM 杀掉（DPanel 计划任务超时常见） |

## 9. 与 v1.x 的差别

| 方面 | v1.x | 当前版本 |
|---|---|---|
| 谁拉镜像 | 脚本自己走 Docker Engine API 拉，还盯进度字节数、判卡死、重试 | 容器模式交给 DPanel，Compose 模式交给 `docker compose pull` / daemon（脚本不碰 Registry） |
| 谁重建容器 | 脚本自己按声明式配置重建，还要逐项校验规格 | DPanel 的 `container:upgrade` |
| 谁重建 Compose 项目 | 脚本自己 `docker compose up -d --force-recreate` | 脚本调 `docker compose up -d`，由 compose 自己重建（**不加** `--remove-orphans`） |
| Compose 项目要不要先在 DPanel 登记 | 不涉及（脚本自己管） | 不需要（v2.0.0 曾要求登记，v2.1.0 起不再要求） |
| 回滚点 | `<镜像仓库>:prev` 标签（只留 1 份） | 容器模式：DPanel 的备份容器 `<容器名>-bak-<时间戳>`；Compose 模式：没有备份容器，靠本地旧镜像 |
| 健康门禁 | 脚本自己判断（healthcheck / 观察 30 秒） | 容器模式由 DPanel 的升级流程负责；Compose 模式脚本只确认「容器在运行」 |
| 坏版本钉住 | `<镜像仓库>:bad`，默认 7 天 | 取消 |
| 失败原因 | stdout + 真正的 stderr | 不变（stdout + 真正的 stderr） |
| 事务目录 | `--state-dir` / `STATE_ROOT`，保留回滚现场 | 取消 |
| 互斥锁 | 已移除（并发靠 DPanel 计划任务） | 不变：脚本内部不加锁 |
| 拉取控制参数 | `--pull-retries`、`PULL_RETRIES`、`DIGEST_RETRIES`、`T_STALL`、`T_STALL_FINISH` 等 | 全部作废（拉取由 DPanel / docker compose 负责） |
| 跨版本提示 | `COMPAT_ROOT` 下的 `lastver` | 不变 |

作废的参数与环境变量（命中即中止，退出码 `3`）：

- 参数：`--state-dir`、`--bad-ttl-days`、`--pull-retries`。
- 环境变量：`LOCK_PREFIX`、`STATE_ROOT`、`BAD_TTL_DAYS`、`PULL_RETRIES`、`DIGEST_RETRIES`、`DIGEST_RETRY_WAIT`、`T_STALL`、`T_STALL_FINISH`、`T_PULL_MAX`、`T_UP`、`T_HEALTH`、`HEALTH_TRIES`、`T_ROLLBACK`、`PLAIN_BOOT`、`COMPOSE_BASE`。
- 例外一：`T_INSPECT` 仍被接受，等价于 `DP_T_CHECK`。
- 例外二：`--compose-dir` 与 `COMPOSE_DIR` **已恢复可用**（Compose 模式用它兜底项目目录）。
- 新增的时间预算环境变量：`DP_T_PULL`（Compose 拉取，默认 420 秒）、`DP_T_UP`（Compose 部署，默认 180 秒）；`DP_T_CHECK` / `DP_T_UPGRADE` / `DP_MIN_UPGRADE` 含义不变。

另外，不再产生 `<镜像仓库>:prev` 标签和 `/tmp/.container-autoupdate/compose-*` 事务目录；升级后可以手动清掉（排查脚本 `scripts/ct-stale-lock-check.sh` 会把它们列出来）。

迁移与版本策略见 [README](../README.md#版本与升级)。
