# 全部参数与环境变量

> 语言：[中文](parameters.md) | [English](parameters.en.md)

> v2.1.0 起两条路各用各的长处：**容器交给 DPanel**（`container:upgrade`，先检查、确实有新版本才升级），**Compose 项目交给 docker 自己的 compose**（`docker compose pull` + `docker compose up -d` 就地重新部署）。
> 脚本自己只做三件事：判断这个目标该不该更新、把更新动作转交给执行者、把结果如实报出来。
> 所以它是给 **DPanel 计划任务**用的：跑一轮就结束，频率与并发交给 DPanel；同一目标只挂一个计划任务即可（脚本内部不加互斥锁）。
> 手动运行也允许，那只是单次运行；不建议再套 cron / systemd timer。

## 前置条件：谁执行更新动作

**只有容器模式依赖 DPanel。** Compose 模式只用 `docker` 与 Compose v2 插件，**完全不碰 DPanel**，所以项目**不需要**先在 DPanel 网页里登记（v2.0.0 的 `compose:deploy` 才要求登记）。

- 容器模式：更新能力来自 DPanel 自己的命令行（DPanel 1.11.x 自带 `container:upgrade`），脚本不自己写 Docker（不 pull、不 tag、不 create、不 rm）。
  - 在 **dpanel 容器里跑**最省事（DPanel 的「计划任务」默认就是在该容器内执行）：脚本直接执行 `/app/server/dpanel`。
  - 也可以在宿主或别的容器里跑：脚本改用 `docker exec dpanel /app/server/dpanel ...`，这时要有 `docker` 命令；容器名不叫 `dpanel` 时用 `--dpanel-container` 指定。
- Compose 模式：脚本先认出项目目录与 compose 文件，再在那个目录里跑 `docker compose pull` 与 `docker compose up -d`。需要 `docker` 命令与 **Compose v2 插件**（`docker compose`，不是 `docker-compose`）。

两种模式：

| 你的容器是怎么起的 | 用哪个参数 | 脚本实际执行 |
|---|---|---|
| `docker compose up -d` | `--compose <项目名>` | `docker compose pull` + `docker compose up -d`（在项目目录里就地重新部署） |
| `docker run ...` | `--container <容器名>` | `dpanel container:upgrade --name <容器名> --docker-env <环境名>`（先不带 `--upgrade` 检查，确实有新版本才再加 `--upgrade`） |

Compose 模式的目录与文件默认不用你配置。脚本先找出属于该项目的容器：

```sh
docker ps -a --filter label=com.docker.compose.project=<项目名>
```

再 `docker inspect` 读它身上的三个标签：`com.docker.compose.project.working_dir`（目录）、`com.docker.compose.project.config_files`（compose 文件）、`com.docker.compose.project.environment_file`（env 文件）。只有反查不到（项目里连一个容器都没有）时才用 `--compose-dir` / `COMPOSE_DIR` 兜底。

安全边界（要记住的几条）：

- Compose 模式只用 compose 自己的 `pull` / `up -d`：不手工 tag、不手工 create、不删任何东西，**不加 `--remove-orphans`**（它会删掉不在当前 compose 文件里的容器，属于数据事故）。
- compose 的参数一律走环境变量（`COMPOSE_PROJECT_NAME` / `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` / `COMPOSE_ENV_FILES`），不拼进命令行——路径含空格时 compose 会打印 Usage 却返回 `0`（静默出错）。
- 脚本不碰 Registry：镜像怎么拉、走哪个加速源，由 docker daemon / DPanel 按你的配置决定（不需要「多镜像地址并行竞速」）。
- 脚本不判断「镜像里是不是坏版本」：容器模式靠 DPanel（起不来时 DPanel 会自行回滚），Compose 模式靠「拉取或部署失败就不部署」与「起不来的容器会被点出来」。
- 健康与业务正确性不归脚本管：脚本只保证「compose 命令成功」+「容器在运行」。**数据不回滚**，生产数据库仍应另有备份。

回滚点（两种模式不一样）：

- **容器模式**：回滚点 = DPanel 生成的**备份容器**，名字形如 `<容器名>-bak-<时间戳>`（例如 `myapp-bak-20261103163808`），它跑着升级前的镜像、处于 Exited 状态。DPanel 网页里能直接看到它；命令行恢复：

```sh
docker stop <新容器> && docker rm <新容器>
docker rename <容器名>-bak-<时间戳> <容器名>
docker start <容器名>
```

- **Compose 模式：没有备份容器，也不维护 `<仓库>:prev`。** 靠「拉取不会删掉旧镜像」这一点：

```sh
# 旧镜像 id 可以从上一轮日志的「已重建：<名>（旧12位 → 新12位）」里看到
docker tag <旧镜像ID> <repo>:latest
docker compose up -d --force-recreate
```

v1.x 的 `<仓库>:prev` 标签与 `/tmp/.container-autoupdate/compose-*` 事务目录从 v2.0.0 起都不再产生；升级后可以手动清掉。

## 指定目标

两种目标**必须且只能指定一个**。两个都给（`--compose a --container b`）会直接报错、退出码 `1`，不做「后者胜出」的静默覆盖。

| 参数 | 说明 |
|---|---|
| `--compose <项目名>` | Compose 项目名，即 `docker compose` 的 project name（通常是目录名，`docker compose ls` 能看到）。目录与 compose 文件默认从容器标签反查 |
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

下面与 `parse_args()` 的 `case` 分支一一对应（另有 `*)` 兜底：命中已登记移除的写法走退出码 `3`，其余未知参数报 `ERR 未知参数：<参数>（用 --help 查看用法）` 并以退出码 `1` 结束）。

| 参数 | 默认 | 什么时候需要它 |
|---|---|---|
| `--compose <项目名>` | 无 | Compose 模式必填。目录与 compose 文件默认从容器标签反查（见上一节） |
| `--container <容器名>` | 无 | 容器模式必填 |
| `--docker-sock <路径>` | 空 | Docker socket **不在默认位置**时（rootless Docker 的 `/run/user/1000/docker.sock`、socket 挂在非常规路径）。设了它脚本会 `export DOCKER_HOST=unix://<路径>`，**覆盖** `DOCKER_HOST`。Compose 模式一定要用 docker CLI，所以它在 Compose 模式下也生效 |
| `--compose-dir <路径>` | 空 | Compose 项目目录。**v2.0.0 曾移除，v2.1.0 起恢复可用**：只在反查不到项目目录时作兜底（项目里一个容器都没有，或容器上没有 compose 标签） |
| `--dpanel-container <名字>` | `dpanel` | **不在 dpanel 容器内**、而 DPanel 容器叫别的名字时（脚本用 `docker exec <名字> ...` 调用 DPanel CLI）。只有容器模式用到 |
| `--dpanel-bin <路径>` | `/app/server/dpanel` | DPanel CLI 在容器里的路径不是默认值时。注意：脚本用「配置区 / `DPANEL_BIN` 里的这个路径可执行」判断自己是否已在 DPanel 容器内，这个判断在解析命令行**之前**完成，所以 `--dpanel-bin` 只改变实际调用的二进制，不改变这个判断。只有容器模式用到 |
| `--dpanel-docker-env <名字>` | `local` | 你的 DPanel 里那台 Docker 服务器不叫 `local` 时（对应 DPanel「Docker 服务器」里的环境名）。只有容器模式用到 |
| `--compat <版本>` | 关 | **声明「我只验证到某个版本」**。脚本比它新、且中间有已登记的破坏性变更就硬停，而不是冒险执行；值非法（形如 `1..2`）、给了空值、或比脚本还新也一并中止（退出码 `3`） |
| `--dry-run` | 关 | 只检查不动手，**两种模式行为不同**（见下）。首次接入、排查「为什么没更新」时用 |
| `-h` / `--help` | — | 显示帮助，退出码 `0` |
| `-V` / `--version` | — | 显示版本号，退出码 `0` |

每个带值的参数缺了值都会报 `ERR <参数> 缺少参数` 并退出 `1`。

### `--dry-run` 在两种模式下的差别

| 模式 | 脚本实际做什么 | 退出码 |
|---|---|---|
| 容器 | 调 DPanel 的检查接口（`container:upgrade` 不带 `--upgrade`）：有新版本就打 `发现新版本（远端 digest=…）` 与 `DRY 只检查不动手，本轮不升级`，**不升级**，容器一点没动；已是最新则打 `OK 容器 <名> 已是最新（DPanel 报告 status=latest）` | `0` |
| Compose | 先认出项目、`docker compose config --images` 列出项目涉及的镜像，再打两行 `DRY` 说明；**不拉取、不部署**，项目一点没动 | `0` |

容器模式：

```text
[2026-11-03 06:00:12] MODE container 容器=myapp
[2026-11-03 06:00:12] 发现新版本（远端 digest=sha256:a5c10db1...）
[2026-11-03 06:00:12] DRY 只检查不动手，本轮不升级
```

Compose 模式：

```text
[2026-11-03 06:00:12] MODE compose 项目=myapp
[2026-11-03 06:00:12]     目录=/srv/myapp
[2026-11-03 06:00:12]     文件=/srv/myapp/docker-compose.yml
[2026-11-03 06:00:12]     镜像: ghcr.1ms.run/yetone/magpie:latest
[2026-11-03 06:00:12] DRY 只检查不动手：上面是这个项目涉及的镜像，本轮不拉取、不部署
[2026-11-03 06:00:12]     要真正更新就去掉 --dry-run（拉取本身就是「有没有新版本」的判断）
```

> 两种模式下 `--dry-run` 的含义确实不同：容器模式是**真去问 DPanel**「有没有新版本」，Compose 模式只是**列出这个项目涉及的镜像**——Compose 没有「只检查有没有新版本」这种能力，拉取本身就是判断。
>
> Compose 模式的 `--dry-run` 也要先能认出项目：反查不到目录又没给 `--compose-dir` 时会直接报错、退出码 `1`。

## 全部环境变量

命令行 > 环境变量 > 配置区；前两项与同名参数完全等价。

| 变量 | 对应参数 | 默认 | 什么时候需要它 |
|---|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | `--compose` / `--container` | 空 | DPanel 的 Environment 面板里配，或一条命令服务多个目标 |
| `DOCKER_SOCK` | `--docker-sock` | 空 | 同上；设了它脚本会 `export DOCKER_HOST=unix://$DOCKER_SOCK`（覆盖 `DOCKER_HOST`） |
| `DOCKER_HOST` | — | docker CLI 自己的默认值 | docker CLI 的标准变量，脚本不覆盖它；`unix:///path` 与 `tcp://host:port` 都行 |
| `DPANEL_NAME` | `--dpanel-container` | `dpanel` | 容器模式：DPanel 容器名 |
| `DPANEL_BIN` | `--dpanel-bin` | `/app/server/dpanel` | 容器模式：DPanel CLI 在容器里的路径；也参与「是否已在 DPanel 容器内」的判断 |
| `DPANEL_DOCKER_ENV` | `--dpanel-docker-env` | `local` | 容器模式：DPanel 里的 docker 环境名 |
| `COMPOSE_DIR` | `--compose-dir` | 空 | **v2.0.0 曾移除，v2.1.0 起恢复可用**：反查不到项目目录时兜底 |
| `COMPAT_ROOT` | — | `/tmp/.container-autoupdate/compat` | 跨版本提示的记录目录（每个目标一个子目录，里面放 `lastver`）。`/tmp` 重启会被清空、或想让记录长留时改到持久目录 |
| `COMPAT_UNTIL` | `--compat` | 空 | 同上 |
| `DRY_RUN` | `--dry-run` | `0` | 设 `1` 等价于 `--dry-run` |
| `T_HARD` | — | `540` | 整轮时间硬上限（秒）。计划任务的「执行超时」更短时调小 |
| `DP_T_CHECK` | — | `120` | 单次「检查」类调用的超时秒数：Compose 模式的 `docker compose config --images`、DPanel CLI `version` 自检、容器模式的检查调用。DPanel / compose 响应慢时调大 |
| `T_INSPECT` | — | 空 | **旧名字，仍然接受**：只在 `DP_T_CHECK` 没设时用作它的默认值，与 `DP_T_CHECK` 等价；两个都设时以 `DP_T_CHECK` 为准 |
| `DP_T_UPGRADE` | — | `420` | 单次**容器升级**调用（`container:upgrade --upgrade`）的超时秒数；实际还会被剩余预算（按 `T_HARD` 算）收敛 |
| `DP_T_PULL` | — | `420` | **v2.1.0 新增**：Compose 模式单次 `docker compose pull` 的超时秒数；同样被剩余预算收敛 |
| `DP_T_UP` | — | `180` | **v2.1.0 新增**：Compose 模式单次 `docker compose up -d` 的超时秒数；同样被剩余预算收敛 |
| `DP_MIN_UPGRADE` | — | `90` | 剩余预算低于这个值就不动手，避免被计划任务半路杀掉；容器升级与 Compose 部署（拉取 + 重新部署）都受它约束 |

## 时间预算与计划任务超时

一条硬规则：**脚本自己的上限要明显小于 DPanel 计划任务的「执行超时」**。
每次调用还会按剩余预算再收敛一次（最低 10 秒）：实际超时取「配置值」与「剩余时间」的较小值。

| 环节 | 默认 | 说明 |
|---|---|---|
| 整轮硬上限 `T_HARD` | 540 秒 | 剩余预算按它算；`DP_MIN_UPGRADE` 用它判断「还来不来得及」 |
| 单次检查 `DP_T_CHECK` | 120 秒 | 容器模式的检查调用、DPanel CLI `version` 自检、Compose 模式的 `docker compose config --images` |
| 单次容器升级 `DP_T_UPGRADE` | 420 秒 | 容器模式真正升级那一次 |
| Compose 拉取 `DP_T_PULL` | 420 秒 | Compose 模式的 `docker compose pull` |
| Compose 重新部署 `DP_T_UP` | 180 秒 | Compose 模式的 `docker compose up -d` |
| 剩余预算闸门 `DP_MIN_UPGRADE` | 90 秒 | 剩余时间低于它就不动手：容器升级与 Compose 部署都会提前收手并如实报错（退出码 `1`） |
| DPanel 计划任务的「执行超时」 | 建议 `600` | 必须大于 `T_HARD`。被 DPanel SIGKILL 的那一轮日志里只剩 `signal: killed`（进程来不及 flush，message 是空串），什么都查不到 |

## 依赖

脚本动手前会自检，缺点什么就报错并以退出码 `1` 结束，不会跑到一半才炸。

| 命令 / 程序 | 用途 | 什么时候需要 |
|---|---|---|
| `timeout` | 给每次 docker / DPanel 调用套超时，防止整轮被计划任务的执行超时 SIGKILL | 一直需要 |
| `sed` `awk` `grep` | 从 DPanel CLI 输出里挑出结果 JSON、清掉 DEBUG 噪声；给 `docker compose config --images` 去重 | 一直需要；busybox 自带的那套就够，不需要 GNU 版 |
| `docker` | Compose 模式跑 `docker compose` / `docker ps` / `docker inspect`；容器模式用 `docker exec` 进 DPanel 容器 | Compose 模式一直需要；容器模式**只有「不在 dpanel 容器内」时需要** |
| Compose v2 插件（`docker compose`） | Compose 模式真正的更新动作（`pull` / `up -d`） | **只有 Compose 模式需要** |
| DPanel CLI（默认 `/app/server/dpanel`） | 容器模式的检查与升级 | **只有容器模式需要** |

不再需要的：`curl`、`flock`、`docker buildx`（脚本既不自己碰 Registry、也不自己实现互斥锁）。

自检报错时会说清是哪一类：

```text
ERR 缺少依赖命令： docker
    需要 timeout 与 busybox 或 coreutils 基础工具；
    Compose 模式还需要 docker（含 docker compose 插件）；不在 DPanel 容器里跑时也需要 docker

ERR 无法连接 Docker（DOCKER_HOST=未设置）
    请确认 Docker 正在运行，且当前用户有权限访问 socket

ERR 无法执行 docker compose（缺 compose 插件？）
    Compose 模式需要 Docker Compose v2 插件版（docker compose，不是 docker-compose）
```

容器模式自检还会调用一次 DPanel CLI（`dpanel version`）：取不到版本号就报 `ERR 无法调用 DPanel CLI（<路径>）` 并退出 `1`；不在容器内时还会给出 `已尝试：docker exec <DPANEL_NAME> <DPANEL_BIN> version`，并提示用 `--dpanel-container` / `--dpanel-bin` 调整。**Compose 模式不做这一步。**

## 已移除的参数与环境变量（写了就中止，退出码 3）

自建拉取、重建容器、健康门禁、`:prev` 回滚点、状态 / 事务目录这些活已经不在脚本里，所以下面这些写法**已经失效**。命中任意一个，脚本会**立刻中止**：本次不做任何改动，退出码 `3`，日志里给出「从哪个版本起改成什么 / 原因 / 迁移方式」。

### 已移除的参数

| 旧写法 | 迁移方式 |
|---|---|
| `--state-dir` | 删掉。脚本不再维护状态目录；跨版本提示记录改到 `COMPAT_ROOT` |
| `--bad-ttl-days` | 删掉。不再有「坏版本钉住」，回滚交给执行者（容器模式用 DPanel 的备份容器，Compose 模式用本地旧镜像） |
| `--pull-retries` | 删掉。容器模式的拉取由 DPanel 完成，Compose 模式的拉取由 `docker compose pull` 完成，脚本不再管理拉取与重试（超时分别用 `DP_T_UPGRADE` / `DP_T_PULL`） |

> `--compose-dir` **不在**这个名单里：它在 v2.0.0 被移除，**v2.1.0 起恢复可用**（见上面的参数表）。

### 已移除的环境变量

| 旧写法 | 迁移方式 |
|---|---|
| `STATE_ROOT` | 删掉；跨版本提示记录改用 `COMPAT_ROOT`（默认 `/tmp/.container-autoupdate/compat`） |
| `BAD_TTL_DAYS` | 删掉；不再有「坏版本钉住」与 TTL，回滚交给执行者 |
| `PULL_RETRIES` | 删掉；拉取由执行者完成（容器模式 DPanel、Compose 模式 `docker compose pull`），脚本不再管理拉取与重试 |
| `DIGEST_RETRIES` | 删掉；远端有没有新版本由执行者判断，脚本不再自己查 digest |
| `DIGEST_RETRY_WAIT` | 删掉；同上：远端 digest 不再由脚本查询 |
| `T_STALL` | 删掉；脚本不再读 Docker 拉取流，拉取停滞判定取消 |
| `T_STALL_FINISH` | 删掉；拉取收尾宽限不再由脚本处理 |
| `T_PULL_MAX` | 删掉；拉取交给执行者，脚本侧可用 `DP_T_PULL` / `DP_T_UPGRADE` 限制单次调用的时长 |
| `T_UP` | 删掉；容器重建由 DPanel 完成（`DP_T_UPGRADE` 控制脚本等待多久）；Compose 侧重部署用 `DP_T_UP` |
| `T_HEALTH` | 删掉；健康观察由执行者负责 |
| `HEALTH_TRIES` | 删掉；健康门禁已移除 |
| `T_ROLLBACK` | 删掉；回滚由执行者负责（容器模式是 DPanel 的备份机制） |
| `PLAIN_BOOT` | 删掉；无 healthcheck 容器的观察已移除 |
| `COMPOSE_BASE` | 删掉；不再需要「从容器标签反查 Compose 目录的基路径」（反查用 compose 自己写在容器上的标签） |
| `LOCK_PREFIX` | 删掉。v1.0.0 起脚本就不再使用互斥锁（并发由 DPanel 计划任务保证），但它一直留在登记表里，所以今天设了它**照样会命中中止** |

> `T_INSPECT` **不在**这个名单里：它是旧名字，仍然接受，等价于 `DP_T_CHECK`（见上一张表）。
>
> `COMPOSE_DIR` **也不在**这个名单里：v2.0.0 曾移除，**v2.1.0 起恢复可用**，等价于 `--compose-dir`。
>
> 环境变量必须**非空**才会命中（`STATE_ROOT=` 这种空值不算）。

命中时的日志长这样（以 `STATE_ROOT` 为例）：

```text
[2026-11-03 06:00:12] ERR 这个环境变量已经不能用了：STATE_ROOT（当前值=/tmp/ct-state）
[2026-11-03 06:00:12]     从 v2.0.0 起：STATE_ROOT 已移除
[2026-11-03 06:00:12]     原因：2.0.0 起脚本不再维护状态目录；跨版本提示记录改到 COMPAT_ROOT（默认 /tmp/.container-autoupdate/compat）
[2026-11-03 06:00:12]     迁移方式：删掉 STATE_ROOT 即可，不需要任何替代设置
[2026-11-03 06:00:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-03 06:00:12]     本次未做任何改动，退出码 3
```

已移除的**参数**命中时是同一套句子，只把名字换掉。注意这些登记项的「新写法」在 `BREAKING_TABLE` 里填的都是「删除这个参数」/「删除这个环境变量」，所以脚本打的**不是**「把 X 换成 删除这个参数」，而是直接说「删掉 X 即可，不需要任何替代设置」：

```text
[2026-11-03 06:00:12] ERR 这个参数已经不能用了：--state-dir
[2026-11-03 06:00:12]     从 v2.0.0 起：--state-dir 已移除
[2026-11-03 06:00:12]     原因：2.0.0 起脚本不再维护状态目录；跨版本提示记录改到 COMPAT_ROOT
[2026-11-03 06:00:12]     迁移方式：删掉 --state-dir 即可，不需要任何替代设置
[2026-11-03 06:00:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-03 06:00:12]     本次未做任何改动，退出码 3
```

## 退出码

| 码 | 含义 | 该怎么办 |
|---|---|---|
| `0` | 成功；或已是最新（容器模式）/「拉取后没有容器需要重建」（Compose 模式）；或 `--dry-run` 只检查完；`-h` / `--help` 与 `-V` / `--version` 也是 | 无需处理 |
| `1` | 配置 / 环境错误（目标没指定或给了两个、缺依赖、连不上 Docker、没有 Compose v2 插件、调不动 DPanel CLI、认不出 Compose 项目目录），或本轮没能完成更新（**容器 / 项目保持原样**） | 看日志里的 `ERR`，改完重跑 |
| `2` | **保留位**：当前版本不产生（旧版表示「回滚失败」；现在容器回滚归 DPanel，Compose 就地重新部署失败时脚本不部署，不会留下半新半旧的项目） | 真看到它时按日志提示处理 |
| `3` | **检测到破坏性变更**：用了已移除的参数 / 环境变量，或 `--compat` 声明得比脚本旧（或值非法 / 为空）（本次未做任何改动） | 按日志里的「迁移方式」改命令；或把下载地址固定到旧版本；或调整 `--compat` |
| `130` | 被 `SIGINT`（Ctrl-C）中断 | 手动跑时按了 Ctrl-C，无妨 |
| `143` | 被 `SIGTERM` / `SIGHUP` 中断（**计划任务执行超时最常见**） | 「执行超时」太短：调大它，或调小 `T_HARD` |

## 常见场景怎么配

| 场景 | 配置 |
|---|---|
| 普通 Compose 项目 | `--compose myapp`，其余全默认。项目目录会自动从容器标签反查，通常不用配 |
| 反查不到 Compose 项目目录 | 加 `--compose-dir <路径>`（或设 `COMPOSE_DIR`）；也可以先手动 `docker compose up -d` 一次，让 compose 的标签落到容器上 |
| 普通 `docker run` 容器 | `--container mycontainer`，其余全默认 |
| Compose 模式、机器上没装 DPanel | 不用装：Compose 模式只要 `docker` 与 Compose v2 插件 |
| 升到新版后一跑就退出码 `3` | 日志里第一条 `ERR` 就是原因：删掉那个已移除的参数 / 环境变量（`--state-dir`、`STATE_ROOT` 之类）。`--compose-dir` / `COMPOSE_DIR` **不在**此列；实在要沿用旧行为，就把下载地址锁到旧版本的 tag |
| Compose 有容器起不来 | 脚本报 `ERR 有容器没在运行（R/M running）：` 并逐条列出没在运行的容器，退出码 `1`；用 `docker compose logs <服务名>` 看具体原因 |
| 不在 dpanel 容器内跑（容器模式） | 本机要有 `docker`；`--dpanel-container <实际容器名>`（默认 `dpanel`），路径不同再加 `--dpanel-bin <路径>`；DPanel 里那台 Docker 服务器不叫 `local` 时加 `--dpanel-docker-env <名字>` |
| 计划任务超时（退出码 `143`） | 先把 DPanel 计划任务的「执行超时」加到 `600` 以上（必须大于 `T_HARD`）；再按需调 `T_HARD`、`DP_T_UPGRADE`（容器升级慢）、`DP_T_PULL` / `DP_T_UP`（Compose 拉取 / 重新部署慢） |
| 检查调用经常超时 | 调大 `DP_T_CHECK`（默认 120） |
| Compose 拉取经常超时 | 调大 `DP_T_PULL`（默认 420） |
| Compose 重新部署经常超时 | 调大 `DP_T_UP`（默认 180） |
| 想先看会怎么处理 | 容器模式加 `--dry-run`（真去问 DPanel 有没有新版本）；Compose 模式加 `--dry-run`（只列出项目涉及的镜像，不拉取不部署） |
| 跨版本时想看到提示 | 默认就会打（记录写在 `COMPAT_ROOT` 下）；`/tmp` 会被清掉的话，把 `COMPAT_ROOT` 改到持久目录 |
| 脚本升到新版、但你想先稳住现有行为 | `--compat <你验证过的版本>`，例如 `--compat 1.2.3` |
| 计划任务里只看到「exit status 1」，看不到原因 | 看 [失败原因写到哪里](#失败原因写到哪里) |

## 失败原因写到哪里

脚本的输出分两路：

- **stdout**：完整日志（含每一条 `ERR` / `CRITICAL` 和它们的补充说明行）。
- **stderr**：**只有失败原因** —— `ERR` / `CRITICAL` 行，以及紧随其后的缩进补充行。

为什么单独写一份 stderr：计划任务（DPanel）在任务**失败**时只保留 stderr、丢掉 stdout。
早期版本只把失败原因写在 stdout，于是计划任务里只剩一句干巴巴的 `exit status 1`，什么都排查不出来。
现在失败原因同时写两路：日志照样完整，失败时计划任务也能直接看到原因。

```text
[2026-11-03 06:00:12] ERR 找不到 Compose 项目 myapp 的项目目录
[2026-11-03 06:00:12]     当前 Docker 里没有带「myapp」这个 compose 项目标签的容器，反查不到
[2026-11-03 06:00:12]     处理方式二选一：
[2026-11-03 06:00:12]       1) 用 --compose-dir <路径> 指定 compose 文件所在目录
[2026-11-03 06:00:12]       2) 确认项目名写法；项目还没部署过就先手动 compose up 一次
```

Compose 模式的两处更新动作失败也是同一套写法（末尾附上 compose 自己的原话，最多 5 行）：

```text
[2026-11-03 06:00:12] ERR 拉取失败（docker compose pull 退出码 1），本轮不部署，项目保持原样
[2026-11-03 06:00:12]     <compose 输出的最后 5 行>
```

手动跑的时候两个流都在终端上，看不出区别；也可以自己分开看：

```sh
sh container-autoupdate.sh --compose myapp >/tmp/ct.out 2>/tmp/ct.err
# /tmp/ct.out 完整日志，/tmp/ct.err 只有失败原因
```

## 引导器（v3.0.0 起已取消）

早期版本还有一个引导器 `ct-bootstrap.sh`，负责下载与缓存主脚本。v3.0.0 起它被取消：整套脚本不到 50KB，计划任务里直接「下载 → 校验 → 执行」就够，缓存与版本探测都没有价值了。

随它一起作废的有 9 个环境变量（`CT_VERSION`、`CT_CACHE_DIR`、`CT_CACHE_KEEP`、`CT_SOURCE`、`CT_T_NET`、`CT_TRIES`、`CT_PROBE_BYTES`、`CT_FORCE`、`CT_QUIET`）与全部 `--ct-*` 参数。任务里还留着的话，脚本会立刻停下（退出码 `3`）并给出迁移方式；新写法见 [快速开始](../README.md#快速开始)，想锁版本就把下载地址换成带 tag 的。
