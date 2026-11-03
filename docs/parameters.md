# 全部参数与环境变量

> 语言：[中文](parameters.md) | [English](parameters.en.md)

> v2.0.0 起，脚本**不再自己拉镜像、不再自己重建容器**：它只做三件事 —— 判断该不该更新、把更新动作交给 DPanel、如实报结果。
> 所以它是给 **DPanel 计划任务**用的：跑一轮就结束，频率与并发交给 DPanel；同一目标只挂一个计划任务即可（脚本内部不加互斥锁）。
> 手动运行也允许，那只是单次运行；不建议再套 cron / systemd timer。

## 前置条件：更新动作由 DPanel 执行

更新能力来自 DPanel 自己的命令行（DPanel 1.11.x 自带 `container:upgrade` / `compose:deploy`），脚本不自己写 Docker（不 pull、不 tag、不 create、不 rm）。因此：

- 必须在**装了 DPanel 的机器**上用。
- **推荐在 dpanel 容器里跑**（DPanel 的「计划任务」默认就是在该容器内执行）：脚本直接执行 `/app/server/dpanel`，连本机 `docker` 命令都不需要。
- 也可以跑在宿主或别的容器里：脚本改用 `docker exec dpanel /app/server/dpanel ...`，这时本机要有 `docker` 命令；容器名不叫 `dpanel` 时用 `--dpanel-container` 指定。
- **Compose 模式要求该项目已经在 DPanel 里登记过**（DPanel 网页 → Compose → 新建 / 导入）。没登记时 DPanel 返回 `commonDataNotFoundOrDeleted`，脚本会识别出来并给出两条迁移指引，退出码 `1`。

两种模式：

| 你的容器是怎么起的 | 用哪个参数 | 脚本实际执行 |
|---|---|---|
| `docker compose up -d` | `--compose <项目名>` | `dpanel compose:deploy --name <项目名> --pull-image dpanel --docker-env <环境名>` |
| `docker run ...` | `--container <容器名>` | `dpanel container:upgrade --name <容器名> --docker-env <环境名>`（先不带 `--upgrade` 检查，确实有新版本才再加 `--upgrade`） |

回滚点也变了：

- 容器模式的回滚点是 DPanel 生成的**备份容器**，名字形如 `<容器名>-bak-<时间戳>`（例如 `myapp-bak-20261103163808`），跑着升级前的镜像、处于 Exited 状态。
- Compose 模式**没有备份容器**，回滚只能靠本地还留着的旧镜像：`docker tag <旧镜像ID> <repo>:latest && docker compose up -d --force-recreate`。
- v1.x 的 `<仓库>:prev` 标签、`/tmp/.container-autoupdate/compose-*` 事务目录在 v2.0.0 里都不再产生。

## 指定目标

两种目标**必须且只能指定一个**。两个都给（`--compose a --container b`）会直接报错、退出码 `1`，不做「后者胜出」的静默覆盖。

| 参数 | 说明 |
|---|---|
| `--compose <项目名>` | Compose 项目名，即 `docker compose` 的 project name（通常是目录名，`docker compose ls` 能看到）。该项目必须已在 DPanel 里登记 |
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
| `--compose <项目名>` | 无 | Compose 模式必填。项目必须已在 DPanel 里登记（见上一节） |
| `--container <容器名>` | 无 | 容器模式必填 |
| `--docker-sock <路径>` | 空（用 `DOCKER_HOST` 或 docker CLI 默认的 `/var/run/docker.sock`） | Docker socket **不在默认位置**时（rootless Docker 的 `/run/user/1000/docker.sock`、socket 挂在非常规路径）。设了它脚本会 `export DOCKER_HOST=unix://<路径>`。**只有「不在 dpanel 容器内」时才真正起作用**：那种情况下脚本才会调本机的 docker CLI |
| `--dpanel-container <名字>` | `dpanel` | **不在 dpanel 容器内**、而 DPanel 容器叫别的名字时（脚本会用 `docker exec <名字> ...` 调用 DPanel CLI） |
| `--dpanel-bin <路径>` | `/app/server/dpanel` | DPanel CLI 在容器里的路径不是默认值时。脚本用「这个路径可执行」来判断自己是否已经在 DPanel 容器内，所以路径填错会被误判成「需要从外面 `docker exec`」 |
| `--dpanel-docker-env <名字>` | `local` | 你的 DPanel 里那台 Docker 服务器不叫 `local` 时（对应 DPanel「Docker 服务器」里的环境名） |
| `--compat <版本>` | 关 | **声明「我只验证到某个版本」**。脚本比它新、且中间有破坏性变更就硬停，而不是冒险执行；值非法（形如 `1..2`）或比脚本还新也一并中止（退出码 `3`）。升级脚本后想先稳住现状时用 |
| `--dry-run` | 关 | 只检查不动手，**两种模式行为不同**（见下）。首次接入、排查「为什么没更新」时用 |
| `-h` / `--help` | — | 显示帮助 |
| `-V` / `--version` | — | 显示版本号 |

### `--dry-run` 在两种模式下的差别

| 模式 | 脚本实际做什么 | 退出码 |
|---|---|---|
| 容器 | 调 DPanel 的检查接口（`container:upgrade` 不带 `--upgrade`）。有新版本就报出来，**不执行升级**，容器一点没动 | `0` |
| Compose | **什么都不做**：DPanel 没给 Compose 提供「只检查」接口（`compose:deploy` 就是部署动作）。脚本打印说明后直接返回，不做任何部署 | `0` |

容器模式：

```text
[2026-11-03 06:00:12] 发现新版本（远端 digest=sha256:a5c10db1...）
[2026-11-03 06:00:12] DRY 只检查不动手，本轮不升级
```

Compose 模式：

```text
[2026-11-03 06:00:12] DRY Compose 模式没有「只检查」能力（DPanel 的 compose:deploy 会直接部署）
[2026-11-03 06:00:12]     本轮未执行部署；要检查容器有没有新版本请用 --container 模式
```

> 想在 Compose 上先演练，只能在测试项目上跑；要「只看结果」就用容器模式对项目里的容器做检查。

## 全部环境变量

命令行 > 环境变量 > 配置区；下面前三项与同名参数完全等价。

| 变量 | 对应参数 | 默认 | 什么时候需要它 |
|---|---|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | `--compose` / `--container` | 空 | DPanel 的 Environment 面板里配，或一条命令服务多个目标 |
| `DOCKER_SOCK` | `--docker-sock` | 空 | 同上；设了它脚本会 `export DOCKER_HOST=unix://$DOCKER_SOCK` |
| `DOCKER_HOST` | — | docker CLI 自己的默认值 | docker CLI 的标准变量，脚本不覆盖它；`unix:///path` 与 `tcp://host:port` 都行 |
| `DPANEL_NAME` | `--dpanel-container` | `dpanel` | 同上 |
| `DPANEL_BIN` | `--dpanel-bin` | `/app/server/dpanel` | 同上 |
| `DPANEL_DOCKER_ENV` | `--dpanel-docker-env` | `local` | 同上 |
| `COMPAT_ROOT` | — | `/tmp/.container-autoupdate/compat` | 跨版本提示的记录目录（每个目标一个子目录，里面放 `lastver`）。`/tmp` 重启会被清空、或想让记录长留时改到持久目录 |
| `COMPAT_UNTIL` | `--compat` | 空 | 同上 |
| `DRY_RUN` | `--dry-run` | `0` | 设 `1` 等价于 `--dry-run` |
| `T_HARD` | — | `540` | 整轮时间硬上限（秒）。计划任务的「执行超时」更短时调小 |
| `DP_T_CHECK` | — | `120` | 单次「检查」调用（`container:upgrade` 不带 `--upgrade`、`version` 自检）的超时秒数。DPanel 响应慢时调大 |
| `T_INSPECT` | — | 空 | **旧名字，v2.0.0 仍然接受**：只在 `DP_T_CHECK` 没设时用作它的默认值，与 `DP_T_CHECK` 等价；两个都设时以 `DP_T_CHECK` 为准 |
| `DP_T_UPGRADE` | — | `420` | 单次「升级 / 部署」调用的超时秒数；实际还会被剩余预算（按 `T_HARD` 算）收敛 |
| `DP_MIN_UPGRADE` | — | `90` | 剩余预算低于这个值就不动手，避免被计划任务半路杀掉；容器升级与 Compose 部署都受它约束 |

## 时间预算与计划任务超时

一条硬规则：**脚本自己的上限要明显小于 DPanel 计划任务的「执行超时」**。

| 环节 | 默认 | 说明 |
|---|---|---|
| 整轮硬上限 `T_HARD` | 540 秒 | 剩余预算按它算；`DP_MIN_UPGRADE` 用它判断「还来不来得及」 |
| 单次检查 `DP_T_CHECK` | 120 秒 | 还要被剩余预算收敛，实际取两者较小值（最低 10 秒） |
| 单次升级 / 部署 `DP_T_UPGRADE` | 420 秒 | 同上 |
| DPanel 计划任务的「执行超时」 | 建议 `600` | 必须大于 `T_HARD`。被 DPanel SIGKILL 的那一轮日志里只剩 `signal: killed`（进程来不及 flush，message 是空串），什么都查不到 |

## 依赖

脚本动手前会自检，缺点什么就 `ERR 缺少依赖命令：xxx` 并以退出码 `1` 结束，不会跑到一半才炸。

| 命令 | 用途 | 什么时候需要 |
|---|---|---|
| `timeout` | 给每次 DPanel 调用套超时，防止整轮被计划任务的执行超时 SIGKILL | 一直需要 |
| `sed` `awk` `grep` | 从 DPanel CLI 输出里挑出结果 JSON、清理 DEBUG 噪声 | 一直需要；busybox 自带的那套就够，不需要 GNU 版 |
| `docker` | 用 `docker exec` 进 DPanel 容器调用它的 CLI，以及确认 Docker 连得上 | **只有「不在 dpanel 容器内」时需要** |

不再需要的：`curl`、`flock`、`docker buildx`（v2.0.0 起既不自己碰 Registry、也不自己拉取镜像，脚本内部也没有互斥锁）。

自检还会调用一次 DPanel CLI（`dpanel version`）：取不到版本号就报 `ERR 无法调用 DPanel CLI（<路径>）` 并退出 `1`；不在容器内时还会提示用 `--dpanel-container` / `--dpanel-bin`。Compose 模式另外要求该项目已在 DPanel 里登记。

## v2.0.0 移除的参数与环境变量

拉取、重建、健康门禁、`:prev` 回滚点、状态 / 事务目录这些活，v2.0.0 起全部交给 DPanel，所以下面这些写法**已经失效**。命中任意一个，脚本会**立刻中止**：本次不做任何改动，退出码 `3`，日志里给出「从哪个版本起改成什么 / 原因 / 迁移方式」。

### 已移除的参数

| 旧写法 | 迁移方式 |
|---|---|
| `--compose-dir` | 删掉。Compose 更新由 DPanel 按项目名处理，不再需要项目目录 |
| `--state-dir` | 删掉。脚本不再维护状态目录；跨版本提示记录改到 `COMPAT_ROOT` |
| `--bad-ttl-days` | 删掉。不再有「坏版本钉住」，回滚由 DPanel 负责 |
| `--pull-retries` | 删掉。拉取由 DPanel 完成，脚本不再管理拉取与重试 |

### 已移除的环境变量

| 旧写法 | 迁移方式 |
|---|---|
| `STATE_ROOT` | 删掉；跨版本提示记录改用 `COMPAT_ROOT`（默认 `/tmp/.container-autoupdate/compat`） |
| `BAD_TTL_DAYS` | 删掉；不再有「坏版本钉住」与 TTL，回滚由 DPanel 负责 |
| `PULL_RETRIES` | 删掉；拉取由 DPanel 完成，脚本不再管理拉取与重试 |
| `DIGEST_RETRIES` | 删掉；远端有没有新版本由 DPanel 判断，脚本不再自己查 digest |
| `DIGEST_RETRY_WAIT` | 删掉；同上：远端 digest 由 DPanel 查询 |
| `T_STALL` | 删掉；脚本不再读 Docker 拉取流，拉取停滞判定取消 |
| `T_STALL_FINISH` | 删掉；拉取收尾宽限由 DPanel 自行处理 |
| `T_PULL_MAX` | 删掉；拉取由 DPanel 完成，脚本侧可用 `DP_T_UPGRADE` 限制单次升级调用的时长 |
| `T_UP` | 删掉；容器重建由 DPanel 完成（`DP_T_UPGRADE` 控制脚本等待多久） |
| `T_HEALTH` | 删掉；健康观察由 DPanel 的升级流程负责 |
| `HEALTH_TRIES` | 删掉；健康门禁已移除，由 DPanel 负责 |
| `T_ROLLBACK` | 删掉；回滚由 DPanel 的备份机制负责 |
| `PLAIN_BOOT` | 删掉；无 healthcheck 容器的观察已交由 DPanel |
| `COMPOSE_DIR` | 删掉；Compose 更新由 DPanel 按项目名处理，不再需要项目目录 |
| `COMPOSE_BASE` | 删掉；不再需要从容器标签反查 Compose 目录 |
| `LOCK_PREFIX` | 删掉。v1.0.0 起脚本就不再使用互斥锁（并发由 DPanel 计划任务保证），但它一直留在登记表里，所以今天设了它**照样会命中中止** |

> `T_INSPECT` **不在**这个名单里：它是旧名字，v2.0.0 仍然接受，等价于 `DP_T_CHECK`（见上一张表）。
>
> 环境变量必须**非空**才会命中（`COMPOSE_DIR=` 这种空值不算）。

命中时的日志长这样（以 `COMPOSE_DIR` 为例）：

```text
[2026-11-03 06:00:12] ERR 这个环境变量已经不能用了：COMPOSE_DIR（当前值=/srv/myapp）
[2026-11-03 06:00:12]     从 v2.0.0 起：COMPOSE_DIR 已移除
[2026-11-03 06:00:12]     原因：Compose 更新由 DPanel 按项目名处理，不再需要项目目录
[2026-11-03 06:00:12]     迁移方式：删掉 COMPOSE_DIR 即可，不需要任何替代设置
[2026-11-03 06:00:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-03 06:00:12]     本次未做任何改动，退出码 3
```

已移除的**参数**命中时打的是同一套五行，只是措辞按参数的形状来：登记表里这类参数的「新写法」填的就是「删除这个参数」，所以日志里会写成 `迁移方式：把 --compose-dir 换成 删除这个参数` ——照做即可，删掉它、换成新参数或干脆不传。

## 退出码

| 码 | 含义 | 该怎么办 |
|---|---|---|
| `0` | 成功；或已是最新；或 `--dry-run` 只检查完；或按规则跳过 | 无需处理 |
| `1` | 配置 / 环境错误（目标没指定或给了两个、缺依赖、连不上 Docker、调不动 DPanel CLI），或本轮没能完成更新（**容器 / 项目保持原样**） | 看日志里的 `ERR`，改完重跑 |
| `2` | **保留位**：v2.0.0 目前不产生（旧版表示「回滚失败」，回滚现在归 DPanel，脚本不感知） | 真看到它时按日志提示处理 |
| `3` | **检测到破坏性变更**：用了已移除的参数 / 环境变量，或 `--compat` 声明得比脚本旧（或值非法）（本次未做任何改动） | 按日志里的「迁移方式」改命令；或把下载地址固定到旧版本；或调整 `--compat` |
| `130` | 被 `SIGINT`（Ctrl-C）中断 | 手动跑时按了 Ctrl-C，无妨 |
| `143` | 被 `SIGTERM` / `SIGHUP` 中断（**计划任务执行超时最常见**） | 「执行超时」太短：调大它，或调小 `T_HARD` |

## 常见场景怎么配

| 场景 | 配置 |
|---|---|
| 普通 Compose 项目 | `--compose myapp`，其余全默认（先确认它已在 DPanel 里登记） |
| 普通 `docker run` 容器 | `--container mycontainer`，其余全默认 |
| 升到新版后一跑就退出码 `3` | 日志里第一条 `ERR` 就是原因：删掉那个已移除的参数 / 环境变量（`--state-dir`、`STATE_ROOT`、`COMPOSE_DIR` 之类）；实在要沿用旧行为，就把下载地址锁到旧版本的 tag |
| Compose 报「没有登记」 | 在 DPanel 网页 → Compose 里新建 / 导入该项目，名称填成脚本里的项目名；或改用 `--container <该项目里的容器名>` |
| 不在 dpanel 容器内跑 | 本机要有 `docker`；`--dpanel-container <实际容器名>`（默认 `dpanel`），路径不同再加 `--dpanel-bin <路径>`；DPanel 里那台 Docker 服务器不叫 `local` 时加 `--dpanel-docker-env <名字>` |
| 计划任务超时（退出码 `143`） | 先把 DPanel 计划任务的「执行超时」加到 `600` 以上（必须大于 `T_HARD`）；再按需调 `T_HARD` 与 `DP_T_UPGRADE`（升级慢的大镜像） |
| 检查调用经常超时 | 调大 `DP_T_CHECK`（默认 120） |
| 想先看会怎么处理 | 容器模式加 `--dry-run`；Compose 模式没有只检查能力，只能在测试项目上试 |
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

```
# 计划任务里失败时能看到的就是这些（stderr）
[2026-11-03 06:00:12] ERR DPanel 里没有登记名为 myapp 的 Compose 项目
[2026-11-03 06:00:12]     compose:deploy 只能操作 DPanel「Compose」页面里登记过的项目
[2026-11-03 06:00:12]     处理方式二选一：
[2026-11-03 06:00:12]       1) 在 DPanel 网页里新建 Compose 项目，名称填 myapp（指向它的 docker-compose.yaml）
[2026-11-03 06:00:12]       2) 改用容器模式：--container <该项目里的容器名>
[2026-11-03 06:00:12]     项目未做任何改动
```

手动跑的时候两个流都在终端上，看不出区别；也可以自己分开看：

```sh
sh container-autoupdate.sh --compose myapp >/tmp/ct.out 2>/tmp/ct.err
# /tmp/ct.out 完整日志，/tmp/ct.err 只有失败原因
```

## 引导器（ct-bootstrap.sh）的参数与环境变量

引导器是推荐的使用方式：它负责下载与缓存主脚本，你只维护一行命令。
它自己也需要 `curl`（探测与下载）和 `sh`；不在 dpanel 容器内时同样需要 `docker`。

两种指定方式，优先级：**命令行 `--ct-*` > 环境变量 `CT_*`**。
引导器选项必须写在主脚本参数前面；也可用 `--` 明确分隔。

| 命令行 | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| `--ct-version <版本>` | `CT_VERSION` | 空 | **设了就是固定版本模式**（如 `1.2.3`，带不带 `v` 前缀都行）：不探测远端，本地有就直接跑，**完全不联网**。生产环境推荐设，版本号见 Releases 页面。 |
| `--ct-cache-dir <目录>` | `CT_CACHE_DIR` | `/var/cache/container-autoupdate` | 脚本缓存目录。容器内跑要挂载可写目录，或改到 `/tmp`。 |
| `--ct-cache-keep <N>` | `CT_CACHE_KEEP` | `3` | 保留几个历史版本文件，超出的删掉。设 `0` 表示不裁剪。 |
| `--ct-source <源>` | `CT_SOURCE` | `auto` | 下载源：`auto`（**自建站 → gh-proxy → 直连 → ghproxy.net**）、`direct`、`gh-proxy`、`ghproxy`、`mus`（自建站），或任意自定义前缀（会拼在 `https://github.com/...` 前面）。 |
| `--ct-t-net <秒>` | `CT_T_NET` | `20` | 单次网络操作超时（秒）。探测和下载各自适用。 |
| `--ct-tries <N>` | `CT_TRIES` | `2` | 每个源尝试几次。 |
| `--ct-probe-bytes <N>` | `CT_PROBE_BYTES` | `16000` | 探测版本号时取文件头多少字节（`Range` 请求）。**别调小**：版本行会随着脚本变长而下移，窗口盖不到就会探不到版本号（表现为「探测远端版本失败」）。探不到时引导器会自动把整个文件取下来再解析一次。 |
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
| 未设固定版本 + 探测到版本且本地已有 | 只发一次 Range 请求（默认取文件头 16KB），不下载 |
| 未设固定版本 + 探测到新版本 | 下载完整文件并缓存，然后执行 |
| 探测失败 + 本地有可用缓存 | 用缓存执行，打 `WARN`（退出码取决于主脚本） |
| 探测失败 + 本地无缓存 | `ERR`，退出码 `1`（**不会静默成功**） |
| 缓存文件损坏 | 自动重新下载（校验：语法 + `VERSION` 字段 + 特征字符串） |

> 为什么默认源不是直连：实测（2026-11-03，N1 dpanel 容器内）自建站 `github.mus.pp.ua` 与公共站 `gh-proxy.com` 都能正确转 Release 资产（sha256 与官方一致），但自建站偶发 40 秒超时（5 次成功 3 次），`gh-proxy.com` 5 次全成功、约 1 秒。默认顺序是**自建站优先（快、且是自己控制的），公共站兜底**，再直连、最后 `ghproxy.net`。
>
> 想只用某一个源就设 `--ct-source mus` / `--ct-source gh-proxy` / `--ct-source direct` / `--ct-source ghproxy`，也可以用 `CT_SOURCE=` 写同样的值。
