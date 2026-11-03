# 进阶用法

> 语言：[中文](advanced-usage.md) | [English](advanced-usage.en.md)

> 基础用法看 [README](../README.md)，全部参数见 [参数文档](parameters.md)。
>
> v2.0.0 起，脚本**不再自己拉镜像、不再自己重建容器**：它只判断「该不该更新」，把更新动作交给 DPanel 的命令行
> （容器走 `container:upgrade`，Compose 项目走 `compose:deploy`），再如实报结果。原理与安全边界见 [工作方式与安全边界](how-it-works.md)。
>
> 所以本文讲的是：DPanel 计划任务怎么配、退出码、破坏性变更与迁移、回滚怎么回、升级前的残留怎么清。

## 1. DPanel 计划任务

### 脚本框里写两行

新建计划任务，脚本框里填**两行**：

```sh
# 第一行：把引导器落到本地（自带缓存，同版本不重复下载）
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
# 第二行：跑一轮。--compose 换成你的项目名；普通容器写 --container <容器名>
sh /tmp/ct-bootstrap.sh --compose myapp
```

- 不要写成 `curl ... | sh`：管道写法在下载失败时会**静默成功**（任务日志里看不出这一轮没跑成）。引导器先落地、校验通过才执行，失败时明确返回非 0。
- 生产环境想锁死版本：给引导器加 `--ct-version <版本号>`（或设 `CT_VERSION`；版本号见 [Releases](https://github.com/geekMus/container-autoupdate/releases)），它就不再探测远端、完全不联网。引导器的全部开关见 [参数文档](parameters.md)。
- 两种模式的对应关系：

| 你的容器是怎么起的 | 用哪个参数 | 脚本实际执行 |
|---|---|---|
| `docker compose up -d` | `--compose <项目名>` | `dpanel compose:deploy --name <项目名> --pull-image dpanel` |
| `docker run ...` | `--container <容器名>` | `dpanel container:upgrade --name <容器名>`（先不带 `--upgrade` 检查，确实有新版本才真升级） |

Compose 项目必须**已经在 DPanel 里登记过**（DPanel 网页 → Compose → 新建 / 导入）。没登记会报 `commonDataNotFoundOrDeleted`，见第 7 节。

### 执行超时设 ≥ 600 秒

- 脚本自己的整轮硬上限是 `T_HARD`（默认 540 秒）。DPanel 的「执行超时」必须**明显大于**它，建议 **≥ 600 秒**。
- 单次调用的超时另有控制：`DP_T_CHECK`（检查，默认 120 秒）、`DP_T_UPGRADE`（升级 / 部署，默认 420 秒）；每一次调用还会按剩余预算再收敛一次。
- 超时太短的后果：这一轮被 DPanel 杀掉，退出码 `143`；被 SIGKILL 的那一轮日志里可能只剩一行 `signal: killed`，什么原因都看不到。
- DPanel 在 UI 里编辑任务时会重写任务的设置 JSON，手填的「执行超时」可能被抹掉（实测发生过）。改完排期回来确认一次。
- 剩余预算不足 `DP_MIN_UPGRADE`（默认 90 秒）时脚本**不动手**，如实报错退出码 `1`，下一轮再试。

### 同一目标只挂一个计划任务

脚本内部**不加互斥锁**，并发由 DPanel 计划任务保证。同一个目标同时跑两轮会互相踩；**同一目标只挂一个计划任务**。

不同目标互不影响，可以各自挂一个任务（见第 7 节）。

### 失败时能看到原因

DPanel 计划任务在**失败时只保留 stderr**（成功时只保留 stdout）。所以脚本把失败原因（`ERR` / `CRITICAL` 行，以及紧随其后的缩进补充行）**同时**写 stdout 和真正的 stderr——这是 v1.1.2 起的设计，v2.0.0 保留。计划任务失败时直接就能看到原因，而不是只有一句 `exit status 1`。

> 副作用：手动把 stdout / stderr 合并到同一个文件时，错误行会各出现两次。

### 手动跑一轮

允许，但那只是**单次运行**：

```sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

### 不推荐 cron / systemd timer

脚本不含调度、也不加互斥锁。用 cron / systemd timer 定时跑，你得**自己保证同一目标不会同时跑两轮**。要定时更新就用 DPanel 计划任务。
（确实要用 cron，请在 crontab 表达式里错开时间点。）

### 脚本不碰镜像仓库

镜像的拉取全部由 DPanel / Docker daemon 完成，用的是**你和 daemon 配置的镜像源**。脚本不碰 Registry，所以「多个镜像地址并行竞速」在 v2.0.0 下不再需要、也没有实施（历史上评估过）。

## 2. 退出码

| 退出码 | 含义 | 该做什么 |
|---|---|---|
| `0` | 成功更新 / 已是最新 / `--dry-run` 只检查 | 不用管 |
| `1` | 失败：DPanel 报错、Compose 项目没在 DPanel 登记、剩余时间不足、缺依赖、参数错误（**目标保持原样**） | 看日志里的 `ERR`；脚本不会改动目标 |
| `2` | **保留位**：v2.0.0 目前不产生（回滚由 DPanel 负责，脚本不感知） | — |
| `3` | **检测到破坏性变更**，你的调用方式已失效（本次未做任何改动） | 按日志里的「迁移方式」改命令；或锁版本；或加 `--compat` |
| `130` | 被 `Ctrl-C`（`SIGINT`）中断 | 手动跑时按的，无妨 |
| `143` | 被 `SIGTERM` / `SIGHUP` 中断（计划任务执行超时最常见） | 说明「执行超时」太短；调大它，或调小 `T_HARD` |

## 3. 兼容机制

破坏性变更（参数 / 环境变量 / 行为）登记在脚本的 `BREAKING_TABLE` 里。用 `latest` 也安全，靠的是下面三件事。

### 旧写法命中，立刻中止（退出码 3）

旧参数 / 旧环境变量还在用 → 脚本**立刻中止**，退出码 `3`，日志写明「哪个写法不能用了 / 从哪个版本起改成什么 / 怎么改 / 或者固定旧版本」：

```text
[2026-11-01 03:47:12] ERR 这个环境变量已经不能用了：LOCK_PREFIX（当前值=/tmp/.container-autoupdate）
[2026-11-01 03:47:12]     从 v1.0.0 起：LOCK_PREFIX 已移除
[2026-11-01 03:47:12]     原因：1.0.0 起脚本不再使用互斥锁，并发由 DPanel 计划任务保证
[2026-11-01 03:47:12]     迁移方式：删掉 LOCK_PREFIX 即可，不需要任何替代设置
[2026-11-01 03:47:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-01 03:47:12]     本次未做任何改动，退出码 3
```

v2.0.0 作废的参数与环境变量见第 4 节。

### 跨版本 WARN

脚本记住**每个目标上次跑过的版本**（记在 `COMPAT_ROOT` 下，每个目标一个 `lastver`；默认是 `/tmp/.container-autoupdate/compat/compose-<项目名>/lastver`，容器模式是 `container-<容器名>`）。升级到含破坏性变更的新版时，日志开头会多一段 `WARN`，说明改了什么、该怎么应对，**然后照常执行**：

```text
[2026-11-01 03:52:03] WARN 你从 1.0.0 之前的版本(0.9.0)升级上来，v1.0.0 引入了破坏性变更
[2026-11-01 03:52:03]      变更：1.0.0 起移除脚本内的互斥锁：v0.4.0 的锁会被残留的子进程长期占住，导致之后每一轮都跳过
[2026-11-01 03:52:03]      应对：同一目标只挂一个 DPanel 计划任务
[2026-11-01 03:52:03]      本次仍会继续执行。两条路选一条：
[2026-11-01 03:52:03]        1) 接受上面的新做法（想让下一次破坏性变更前先停住，可加 --compat 1.0.0）
[2026-11-01 03:52:03]        2) 想继续用旧行为，把下载地址固定到 v0.9.0 那个 tag
```

它**不中止**（因为不确定你是否依赖旧行为），只提示。同一版本不重复提示；降级不提示。

> 注意：**别把提示里的旧版本号填进 `--compat`**（例子里是 `0.9.0`）——`--compat` 的语义是「我已经验证到 vX」，填一个比变更版本还旧的版本，等于每次都声明「这个变更我没验证过」，于是**每次运行都硬停**（退出码 `3`）。
> 想「先停住」应该写**当前脚本的版本**（`sh container-autoupdate.sh --version` 可以查；日志首行的 `container-autoupdate v<版本> 启动` 也是它）。

### `--compat <版本>`

声明「我只验证到某个版本」。脚本比它新、且中间有登记在案的 `behavior` 级变更 → **硬停**，退出码 `3`：

```sh
container-autoupdate.sh --compose myapp --compat 1.2.3
```

（`1.2.3` 是示例占位，换成你**验证过**的版本。）

适合：你在生产上验证过某个版本，某天脚本跳到含破坏性变更的新版，你还没时间回归——`--compat` 等于「碰到我没验证过的破坏性变更就别动我的容器」。验证完把数字改成新版本，或直接去掉。

边界行为：

| 情况 | 结果 |
|---|---|
| `--compat` 后面没跟值 | 退出码 `1`（参数错误：缺少参数） |
| 值不合法（如 `abc`、`1..2`），或显式给了空值 | 退出码 `3` |
| 值比脚本还新（通常是下载地址写错了） | 退出码 `3` |
| 值等于或高于变更版本 | 放行 |
| 没有任何登记在案的破坏性变更 | 直接放行，不打扰 |

> 顺序是刻意的：兼容检查在依赖检查**之前**（缺 `docker` 的机器上也要先看到迁移说明）；跨版本 `WARN` 也在依赖检查前打印，但 `lastver` 在依赖检查**之后**才写——依赖缺失的那一轮不算「用户已知悉」。

## 4. 从 v1.x 迁移

### 作废的参数

下面四个参数在 v2.0.0 里**作废**：传了它们，脚本立刻中止、退出码 `3`，日志给出迁移方式。

| 作废的参数 | 原来干什么 | 现在怎么办 |
|---|---|---|
| `--compose-dir` | 告诉脚本 Compose 项目目录 | 不需要了：更新由 DPanel 按**项目名**处理，DPanel 自己知道项目目录 |
| `--state-dir` | 指定状态目录 | 不需要了：跨版本提示的记录改用 `COMPAT_ROOT`（默认 `/tmp/.container-autoupdate/compat`） |
| `--bad-ttl-days` | 坏版本钉住期 | 不需要了：不再有「坏版本钉住」，回滚由 DPanel 负责 |
| `--pull-retries` | 拉取失败重试次数 | 不需要了：拉取由 DPanel 完成，脚本不再管理拉取与重试 |

### 作废的环境变量

下面这些环境变量在 v2.0.0 里作废（仍被设置就中止，退出码 `3`），迁移方式一律是**删掉它**、不需要替代设置：

| 变量 | 原来的用途 |
|---|---|
| `STATE_ROOT` | 状态目录 |
| `BAD_TTL_DAYS` | 坏版本钉住期（天） |
| `PULL_RETRIES` | 拉取失败重试次数 |
| `DIGEST_RETRIES` | 查远端 digest 的重试次数 |
| `DIGEST_RETRY_WAIT` | 查远端 digest 的重试间隔 |
| `T_STALL` | 拉取进度停滞判定 |
| `T_STALL_FINISH` | 拉取收尾宽限 |
| `T_PULL_MAX` | 单次拉取的绝对上限 |
| `T_UP` | 重建 / 启动容器的超时 |
| `T_HEALTH` | 健康门禁的墙钟上限 |
| `HEALTH_TRIES` | 健康检查的轮询次数上限 |
| `T_ROLLBACK` | 回滚操作的超时 |
| `PLAIN_BOOT` | 无 healthcheck 容器的启动观察时长 |
| `COMPOSE_DIR` | Compose 项目目录 |
| `COMPOSE_BASE` | Compose 目录的回退根路径 |

> 例外：`T_INSPECT` **仍然认**，等价于 `DP_T_CHECK`——老任务不改配置也能跑。

### `LOCK_PREFIX` 仍会命中中止

`LOCK_PREFIX` 属于 1.0.0 那次破坏性变更（脚本内部的互斥锁已移除），仍在 `BREAKING_TABLE` 里。启动命令里留着 `LOCK_PREFIX=...` 一样会让脚本中止、退出码 `3`；删掉即可。

### 新的参数与环境变量

| 参数 | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| `--dpanel-container <名字>` | `DPANEL_NAME` | `dpanel` | DPanel 所在容器名（只在「不在 dpanel 容器内跑」时用到） |
| `--dpanel-bin <路径>` | `DPANEL_BIN` | `/app/server/dpanel` | DPanel CLI 路径 |
| `--dpanel-docker-env <名字>` | `DPANEL_DOCKER_ENV` | `local` | 传给 DPanel CLI 的 `--docker-env` |

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMPAT_ROOT` | `/tmp/.container-autoupdate/compat` | 跨版本提示的记录目录（每目标一个 `lastver`） |
| `T_HARD` | `540` | 整轮时间硬上限（秒） |
| `DP_T_CHECK` | `120` | 单次「检查」调用超时（秒）；旧的 `T_INSPECT` 仍被接受 |
| `DP_T_UPGRADE` | `420` | 单次「升级 / 部署」调用超时（秒） |
| `DP_MIN_UPGRADE` | `90` | 剩余预算低于它就不动手（秒） |

保留的参数：`--compose`、`--container`、`--docker-sock`、`--compat`、`--dry-run`、`-h` / `--help`、`-V` / `--version`。全部参数见 [参数文档](parameters.md)。

### 依赖变了

v2.0.0 只需要 `timeout` `sed` `awk` `grep`（busybox / coreutils 都行），**不再需要 `curl`、`flock`**；不在 dpanel 容器内跑时额外需要 `docker`。

## 5. 回滚实操

**这是 v2.0.0 与 v1.x 最大的不同**：回滚点不再是脚本维护的 `:prev` 镜像标签。容器模式和 Compose 模式的回滚能力**不一样**。

### 容器模式：回滚点 = DPanel 的备份容器

DPanel 升级容器时会先生成一个备份容器，名字形如 `<容器名>-bak-<时间戳>`（例如 `myapp-bak-20261103163808`）。它跑着**升级前的镜像**、处于 `Exited` 状态。脚本没有传 DPanel 的 `--disable-bak`，所以备份是默认行为——它就是你的回滚点。

要回滚：

1. 在 DPanel 网页的容器列表里找到 `<容器名>-bak-<时间戳>`（`docker ps -a` 也能看到）。
2. 用 DPanel 的恢复 / 重建功能把它变回原来的容器（原名、原配置、旧镜像）。
3. `docker` 层面的**等价操作**：备份容器保存着旧镜像与原容器配置，可以直接把它改回原名后启动：

```sh
# 找到备份容器，并核对它跑的是旧镜像、处于 Exited
docker ps -a --filter "name=^/<容器名>-bak-"
docker inspect -f '{{.State.Status}} {{.Config.Image}}' <容器名>-bak-<时间戳>

# 让出错的那个容器让位
docker stop <容器名>
docker rm <容器名>

# 把备份容器改回原名并启动
docker rename <容器名>-bak-<时间戳> <容器名>
docker start <容器名>
```

> 备份容器会占磁盘。**确认新版本没问题后再删**（`docker rm <容器名>-bak-<时间戳>`）。
> 回滚只恢复**容器与镜像**，不会撤销新版本已经做过的数据迁移；生产数据库仍应另有备份。

### Compose 模式：没有备份容器，也不维护 `:prev`

DPanel 的 compose 部署**没有备份机制**：Compose 模式**不生成备份容器**，脚本也**不维护 `:prev`**。回滚只能靠**本地还在的旧镜像**：

```sh
# 1. 找到部署前的那个旧镜像 ID
docker images --digests <仓库>
# 2. 把它贴回 :latest，再强制重建
docker tag <旧镜像ID> <仓库>:latest
docker compose up -d --force-recreate
```

这是**应急手段**，别当常规退路：

- 本地没有旧镜像（被清理过）就回不去了——**部署前先确认旧镜像还在**。
- 如果本机还留着 v1.x 时代的 `<仓库>:prev` 标签，也可以直接拿它当旧镜像（`docker tag <仓库>:prev <仓库>:latest` 再重建），但 v2.0.0 不会再移动或维护这个标签。
- 长远做法是**先在一个测试项目上演练**：确认新版本没问题，再让同样的流程作用到生产。

## 6. 排查升级前的残留

v2.0.0 **自己不再产生**互斥锁文件，也不再产生 `/tmp/.container-autoupdate/compose-*` / `plain-*` 事务目录。但**升级前的残留还在**：v1.x 的锁文件、没退干净的拉取进程、事务目录都留在原地。

仓库里带了一个**只读**排查脚本 `scripts/ct-stale-lock-check.sh`：它不改任何东西、不杀任何进程，只把下面这些列出来，末尾给出可复制的清理命令：

1. 旧的互斥锁文件；
2. 谁正开着这些锁文件（PID / PPID / fd / 命令行）；
3. 残留的镜像拉取进程（`images/create`）；
4. `/tmp/.container-autoupdate` 下的残留目录（并标注哪些能删、哪些要留）。

### 怎么用

```sh
curl -fsSL -L https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh \
  -o /tmp/ct-stale-lock-check.sh
sh /tmp/ct-stale-lock-check.sh
```

**要在跑更新的那个环境里跑**：脚本看的是那台机器的 `/proc`。用 DPanel 的话就是容器内部：

```sh
docker cp /tmp/ct-stale-lock-check.sh dpanel:/tmp/ct-stale-lock-check.sh
docker exec -it dpanel sh /tmp/ct-stale-lock-check.sh
```

可选环境变量：`CT_LOCK_PREFIX`（锁文件前缀，默认 `/tmp/.container-autoupdate`）、`CT_STATE_ROOT`（要列出的目录，默认 `/tmp/.container-autoupdate`）。

### 看完结果再清理

确认清单里的东西没人要了，再手工执行：

```sh
# 1) 旧的锁文件（v2.0.0 已不使用锁，留着只是垃圾）
rm -f /tmp/.container-autoupdate/*.lock

# 2) 残留的拉取进程：先看它的命令行，确认是残留再 kill
cat /proc/<PID>/cmdline | tr '\0' ' '
kill <PID>

# 3) v1.x 残留的事务目录（先看里面的日志，确认问题已解决）
rm -rf /tmp/.container-autoupdate/compose-<项目名>
```

`compat/` 目录建议保留：那是跨版本提示的记录（`COMPAT_ROOT`），删掉只会在下次升级时多提示一次。

## 7. 常见问题

**Q：Compose 报 `commonDataNotFoundOrDeleted`，怎么办？**
A：这个项目**没在 DPanel 里登记过**。脚本会识别出来并给出迁移指引（退出码 `1`，项目未做任何改动）：

```text
[2026-11-03 06:00:12] ERR DPanel 里没有登记名为 myapp 的 Compose 项目
[2026-11-03 06:00:12]     compose:deploy 只能操作 DPanel「Compose」页面里登记过的项目
[2026-11-03 06:00:12]     处理方式二选一：
[2026-11-03 06:00:12]       1) 在 DPanel 网页里新建 Compose 项目，名称填 myapp（指向它的 docker-compose.yaml）
[2026-11-03 06:00:12]       2) 改用容器模式：--container <该项目里的容器名>
[2026-11-03 06:00:12]     项目未做任何改动
```

两条路选一条：在 DPanel 网页里新建 / 导入 Compose 项目（名称要与 `--compose` 一致），或改用 `--container`。

**Q：任务失败，日志是「这个参数已经不能用了：xxx」，退出码 `3`。**
A：你的启动命令里还留着 v1.x 的旧写法。按日志里的「迁移方式」改；作废清单见[第 4 节](#4-从-v1x-迁移)。别顺手乱加 `--compat`——填错版本会每次运行都硬停（见[第 3 节](#3-兼容机制)）。

**Q：脚本在宿主上跑，怎么指定 DPanel 容器？**
A：加 `--dpanel-container <容器名>`（默认 `dpanel`）。这时脚本用 `docker exec <容器名> /app/server/dpanel ...` 调用 DPanel，并要求本机有可用的 `docker` 命令（脚本会先 `docker version` 探一下）。DPanel CLI 不在默认路径时用 `--dpanel-bin <路径>`；DPanel 里的 docker 环境名不是 `local` 时用 `--dpanel-docker-env <名字>`。

**Q：计划任务跑到一半被杀，退出码 `143`。**
A：DPanel 的「执行超时」到了。三件事一起看：DPanel 执行超时（设 ≥ 600 秒）、脚本整轮硬上限 `T_HARD`（默认 540 秒）、单次升级 / 部署超时 `DP_T_UPGRADE`（默认 420 秒，实际还会按剩余预算收敛）。**内部超时必须明显小于外部超时**，否则被 SIGKILL 的那一轮日志里可能只剩 `signal: killed`。

**Q：`--dry-run` 在 Compose 模式下什么都没做。**
A：这是如实的：DPanel 的 `compose:deploy` 就是部署动作，没有「只检查」能力。Compose 模式下 `--dry-run` 只打一行说明就退出（退出码 `0`），什么都不动。要预演只能在**测试项目**上真跑一次，或用 `--container` 模式检查单个容器。

**Q：日志说 `OK DPanel 已部署 Compose 项目 X`，是不是就更新到最新版了？**
A：不一定。`OK` 只说明 DPanel 执行完了这次部署（脚本显式传了 `--pull-image dpanel`，让 DPanel 先拉镜像再部署），但部署本身不保证版本一定变了——以 DPanel 的操作记录、或容器实际运行的镜像为准。

**Q：能不能一次更新多个目标？**
A：不能，一个进程一个目标。不同目标可以各自挂一个计划任务；同一目标只挂一个。

**Q：能不能让脚本从多个镜像地址并行取最快的？**
A：不需要。镜像拉取全部由 DPanel / Docker daemon 负责，用的是你和 daemon 配置的镜像源；脚本根本不碰 Registry。这个想法历史上评估过，未实施。
