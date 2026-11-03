# 进阶用法

> 语言：[中文](advanced-usage.md) | [English](advanced-usage.en.md)

> 基础用法看 [README](../README.md)，全部参数见 [参数文档](parameters.md)。
>
> v2.1.0 起，脚本**不再自己拉镜像、不再自己重建容器**：它只判断「该不该更新」，然后按模式把更新动作交出去
> （容器走 DPanel 的 `container:upgrade`，Compose 项目走 `docker compose pull` + `docker compose up -d` 就地重新部署），
> 再如实报结果。原理与安全边界见 [工作方式与安全边界](how-it-works.md)。
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
| `docker compose up -d` | `--compose <项目名>` | `docker compose pull` + `docker compose up -d`（就地重新部署） |
| `docker run ...` | `--container <容器名>` | `dpanel container:upgrade --name <容器名>`（先不带 `--upgrade` 检查，确实有新版本才真升级） |

Compose 模式**不需要项目先登记**：脚本直接从容器标签反查项目目录与 compose 文件；反查不到才用 `--compose-dir` 兜底（见第 7 节）。
容器模式仍然完全依赖 DPanel —— 没有 DPanel 就没法更新容器。

### 执行超时设 ≥ 600 秒

- 脚本自己的整轮硬上限是 `T_HARD`（默认 540 秒）。DPanel 的「执行超时」必须**明显大于**它，建议 **≥ 600 秒**（`scriptRunTimeout=600`）。
- 单次调用的超时另有控制：容器模式 `DP_T_CHECK`（检查，默认 120 秒）、`DP_T_UPGRADE`（升级，默认 420 秒）；
  Compose 模式 `DP_T_CHECK`（列镜像）、`DP_T_PULL`（拉取，默认 420 秒）、`DP_T_UP`（重新部署，默认 180 秒）。
  每一次调用还会按剩余预算再收敛一次。
- 超时太短的后果：这一轮被 DPanel 杀掉，退出码 `143`；被 SIGKILL 的那一轮日志里可能只剩一行 `signal: killed`，什么原因都看不到。
- DPanel 在 UI 里编辑任务时会重写任务的设置 JSON，手填的「执行超时」可能被抹掉（实测发生过）。改完排期回来确认一次。
- 剩余预算不足 `DP_MIN_UPGRADE`（默认 90 秒）时脚本**不动手**，如实报错退出码 `1`，下一轮再试。

### 同一目标只挂一个计划任务

脚本内部**不加互斥锁**，并发由 DPanel 计划任务保证。同一个目标同时跑两轮会互相踩；**同一目标只挂一个计划任务**。

不同目标互不影响，可以各自挂一个任务（见第 7 节）。

### 失败时能看到原因

DPanel 计划任务在**失败时只保留 stderr**（成功时只保留 stdout）。所以脚本把失败原因（`ERR` / `CRITICAL` 行，以及紧随其后的缩进补充行）**同时**写 stdout 和真正的 stderr——这是 v1.1.2 起的设计，一直保留。计划任务失败时直接就能看到原因，而不是只有一句 `exit status 1`。

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

镜像的拉取在 Compose 模式下由 `docker compose pull` 完成，用的是**你和 daemon 配置的镜像源**。脚本不碰 Registry，所以「多个镜像地址并行竞速」不再需要、也没有实施（历史上评估过）。

## 2. 退出码

| 退出码 | 含义 | 该做什么 |
|---|---|---|
| `0` | 成功更新 / 已是最新 / `--dry-run` 只检查 | 不用管 |
| `1` | 失败：容器模式 DPanel 报错、Compose 模式拉取失败 / 重新部署失败 / 部署后有容器没在运行 / 找不到项目目录、剩余时间不足、缺依赖、参数错误（**目标保持原样**） | 看日志里的 `ERR`；脚本不会把目标丢在半新半旧的状态 |
| `2` | **保留位**：目前不产生（容器回滚由 DPanel 负责，脚本不感知；Compose 部署失败时脚本不部署） | — |
| `3` | **检测到破坏性变更**，你的调用方式已失效（本次未做任何改动） | 按日志里的「迁移方式」改命令；或锁版本；或加 `--compat` |
| `130` | 被 `Ctrl-C`（`SIGINT`）中断 | 手动跑时按的，无妨 |
| `143` | 被 `SIGTERM` / `SIGHUP` 中断（计划任务执行超时最常见） | 说明「执行超时」太短；调大它，或调小 `T_HARD` |

### Compose 模式下的失败分别长什么样

Compose 模式只有「部署」这一个动作，失败分三种，**都不会把项目留在半新半旧的状态**：

- **拉取失败**：脚本**不部署**，项目保持原样，退出码 `1`：

```text
[2026-11-03 06:00:12] ERR 拉取失败（docker compose pull 退出码 1），本轮不部署，项目保持原样
[2026-11-03 06:00:12]     <compose 自己的最后 5 行输出>
```

- **重新部署失败**：退出码 `1`，并把 compose 的原话打出来：

```text
[2026-11-03 06:00:12] ERR 重新部署失败（docker compose up -d 退出码 1）
[2026-11-03 06:00:12]     <compose 自己的最后 5 行输出>
[2026-11-03 06:00:12]     compose 文件与容器定义都没被脚本改过，可以直接再跑一轮
```

- **部署成功但有容器没在运行**：退出码 `1`，逐个点名，并提示用 `docker compose logs <服务名>` 看原因：

```text
[2026-11-03 06:00:12] ERR 有容器没在运行（1/3 running）：
[2026-11-03 06:00:12]     myapp-worker exited
[2026-11-03 06:00:12]     compose 文件没被改过；用 docker compose logs <服务名> 看具体原因
```

→ ERR: the pull failed (docker compose pull exit code 1); nothing was deployed this round, the project is untouched
→ ERR: the redeploy failed (docker compose up -d exit code 1)
→     neither the compose file nor the container definitions were changed by the script; you can simply run another round
→ ERR: some containers are not running (1/3 running):
→     myapp-worker exited
→     the compose file was not changed; use docker compose logs <service> to see the reason

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

→ ERR: this environment variable can no longer be used: LOCK_PREFIX (current value=/tmp/.container-autoupdate)
→     as of v1.0.0: LOCK_PREFIX has been removed
→     reason: since 1.0.0 the script no longer uses a mutex lock; concurrency is guaranteed by the DPanel scheduled task
→     migration path: just delete LOCK_PREFIX, no replacement setting is needed
→     or pin the download URL to an old version (see "Versions and upgrades" in the README)
→     nothing was changed this round; exit code 3

作废的参数与环境变量见第 4 节。

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

→ WARN: you upgraded from a version before 1.0.0 (0.9.0); v1.0.0 introduced a breaking change
→       change: since 1.0.0 the mutex lock inside the script is gone ...
→       how to deal with it: put only one DPanel scheduled task on each target
→       this round still continues. Pick one of the two paths:
→        1) accept the new behaviour above (to stop before the next breaking change, add --compat 1.0.0)
→        2) keep the old behaviour and pin the download URL to the v0.9.0 tag

它**不中止**（因为不确定你是否依赖旧行为），只提示。同一版本不重复提示；降级不提示。

> 注意：**别把提示里的旧版本号填进 `--compat`**（例子里是 `0.9.0`）——`--compat` 的语义是「我已经验证到 vX」，填一个比变更版本还旧的版本，等于每次都声明「这个变更我没验证过」，于是**每次运行都硬停**（退出码 `3`）。
> 想「先停住」应该写**当前脚本的版本**（`sh container-autoupdate.sh --version` 可以查；日志首行的 `container-autoupdate v<版本> 启动` 也是它）。

### `--compat <版本>`

声明「我只验证到某个版本」。脚本比它新、且中间有登记在案的 `behavior` 级变更 → **硬停**，退出码 `3`：

```sh
container-autoupdate.sh --compose myapp --compat 1.2.3
```

（`1.2.3` 是示例占位，换成你**验证过**的版本。）

`--compat` 的两种用法正好相反，别填错：

| 你填什么 | 脚本怎么反应 |
|---|---|
| **当前脚本的版本**（`--version` 查） | **本次继续跑**；但以后一旦出现比它更新的破坏性变更，就硬停（退出码 `3`）——这是「先停住」的正确写法 |
| 一个**比变更版本还旧**的版本 | 每次运行都硬停（退出码 `3`）：你在声明「这个变更我没验证过」，而它就在脚本里 |

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

下面三个参数**作废**：传了它们，脚本立刻中止、退出码 `3`，日志给出迁移方式。

| 作废的参数 | 原来干什么 | 现在怎么办 |
|---|---|---|
| `--state-dir` | 指定状态目录 | 不需要了：跨版本提示的记录改用 `COMPAT_ROOT`（默认 `/tmp/.container-autoupdate/compat`） |
| `--bad-ttl-days` | 坏版本钉住期 | 不需要了：不再有「坏版本钉住」，回滚由 DPanel 负责 |
| `--pull-retries` | 拉取失败重试次数 | 不需要了：容器模式拉取由 DPanel 完成，Compose 模式由 `docker compose pull` 完成 |

`--compose-dir` **不在作废清单里**：v2.1.0 起它**恢复可用**，作用和以前一样——告诉脚本 Compose 项目的目录。
它现在是**可选的兜底**：项目里还有容器时，脚本从 `com.docker.compose.project.*` 标签就能反查出目录与 compose 文件；
只有当这个项目一个容器都没有（比如还没部署过）时才需要它。等价的环境变量 `COMPOSE_DIR` 同样恢复可用。

### 作废的环境变量

下面这些环境变量作废（仍被设置就中止，退出码 `3`），迁移方式一律是**删掉它**、不需要替代设置：

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
| `COMPOSE_BASE` | Compose 目录的回退根路径 |

> 两个例外：`T_INSPECT` **仍然认**，等价于 `DP_T_CHECK`——老任务不改配置也能跑；
> `COMPOSE_DIR` **恢复可用**，等价于 `--compose-dir`（见上一小节）。

### DPanel 计划任务里的作废变量要删掉

从 v1.x 沿用下来的计划任务，脚本框或环境变量里往往还留着上面那些作废项。**留着哪一项，脚本就在哪一项上中止（退出码 `3`）**，本轮什么都不做。

```text
[2026-11-01 03:47:12] ERR 这个环境变量已经不能用了：T_STALL（当前值=60）
[2026-11-01 03:47:12]     从 v2.0.0 起：T_STALL 已移除
[2026-11-01 03:47:12]     原因：2.0.0 起脚本不再读 Docker 拉取流，拉取停滞判定取消
[2026-11-01 03:47:12]     迁移方式：删掉 T_STALL 即可，不需要任何替代设置
[2026-11-01 03:47:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-01 03:47:12]     本次未做任何改动，退出码 3
```

→ ERR: this environment variable can no longer be used: T_STALL (current value=60)
→     as of v2.0.0: T_STALL has been removed
→     reason: since 2.0.0 the script no longer reads the Docker pull stream, so stall detection is gone
→     migration path: just delete T_STALL, no replacement setting is needed
→     or pin the download URL to an old version (see "Versions and upgrades" in the README)
→     nothing was changed this round; exit code 3

迁移前后各做一次：

1. **迁移前**：把计划任务的「脚本 / 环境变量」里所有作废项逐个删掉（对着上面的表核一遍）。
2. **迁移后**：手动跑一轮 `sh /tmp/ct-bootstrap.sh --compose myapp --dry-run` 确认脚本认到的目标与项目目录是对的，再去掉 `--dry-run`。

### `LOCK_PREFIX` 仍会命中中止

`LOCK_PREFIX` 属于 1.0.0 那次破坏性变更（脚本内部的互斥锁已移除），仍在 `BREAKING_TABLE` 里。启动命令里留着 `LOCK_PREFIX=...` 一样会让脚本中止、退出码 `3`；删掉即可。

### 新的参数与环境变量

| 参数 | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| `--compose-dir <路径>` | `COMPOSE_DIR` | 空 | Compose 项目目录；反查不到时兜底（v2.1.0 恢复） |
| `--dpanel-container <名字>` | `DPANEL_NAME` | `dpanel` | DPanel 所在容器名（只在「不在 dpanel 容器内跑」时用到） |
| `--dpanel-bin <路径>` | `DPANEL_BIN` | `/app/server/dpanel` | DPanel CLI 路径 |
| `--dpanel-docker-env <名字>` | `DPANEL_DOCKER_ENV` | `local` | 传给 DPanel CLI 的 `--docker-env` |

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMPAT_ROOT` | `/tmp/.container-autoupdate/compat` | 跨版本提示的记录目录（每目标一个 `lastver`） |
| `T_HARD` | `540` | 整轮时间硬上限（秒） |
| `DP_T_CHECK` | `120` | 单次「检查」调用超时（秒）；旧的 `T_INSPECT` 仍被接受 |
| `DP_T_UPGRADE` | `420` | 单次容器升级调用超时（秒） |
| `DP_T_PULL` | `420` | Compose 模式 `docker compose pull` 的超时（秒） |
| `DP_T_UP` | `180` | Compose 模式 `docker compose up -d` 的超时（秒） |
| `DP_MIN_UPGRADE` | `90` | 剩余预算低于它就不动手（秒） |

保留的参数：`--compose`、`--container`、`--docker-sock`、`--compat`、`--dry-run`、`-h` / `--help`、`-V` / `--version`。全部参数见 [参数文档](parameters.md)。

### 依赖变了

脚本只需要 `timeout` `sed` `awk` `grep`（busybox / coreutils 都行），**不再需要 `curl`、`flock`**。
另外：

- **容器模式**：需要 DPanel CLI（脚本用 `dpanel version` 探活）。不在 dpanel 容器内跑时还需要 `docker`。
- **Compose 模式**：需要 `docker` 与 **Docker Compose v2 插件**（`docker compose`，不是 `docker-compose`）。缺了插件会报：

```text
[2026-11-03 06:00:12] ERR 无法执行 docker compose（缺 compose 插件？）
[2026-11-03 06:00:12]     Compose 模式需要 Docker Compose v2 插件版（docker compose，不是 docker-compose）
```

→ ERR: cannot run docker compose (missing the compose plugin?)
→     Compose mode needs the Docker Compose v2 plugin (docker compose, not docker-compose)

## 5. 回滚实操

**这是与 v1.x 最大的不同**：回滚点不再是脚本维护的 `:prev` 镜像标签。容器模式和 Compose 模式的回滚能力**不一样**——一个有备份容器，一个没有。

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

# 让出错的新容器让位
docker stop <容器名>
docker rm <容器名>

# 把备份容器改回原名并启动
docker rename <容器名>-bak-<时间戳> <容器名>
docker start <容器名>
```

> 备份容器会占磁盘。**确认新版本没问题后再删**（`docker rm <容器名>-bak-<时间戳>`）。
> 回滚只恢复**容器与镜像**，不会撤销新版本已经做过的数据迁移；生产数据库仍应另有备份。

### Compose 模式：没有备份容器，也不维护 `:prev`

Compose 模式里 `docker compose up -d` **没有备份机制**：**不生成备份容器**，脚本也**不维护 `:prev`**。回滚只能靠**本地还在的旧镜像**：

```sh
# 1. 找到部署前的那个旧镜像 ID
#    最省事的读法：上一轮日志里的「已重建：<名>（旧12位 → 新12位）」，箭头左边就是旧镜像的 12 位 id
#    也可以自己翻：docker images --digests <仓库>
# 2. 把它贴回 :latest，再强制重建
docker tag <旧镜像ID> <仓库>:latest
docker compose up -d --force-recreate
```

这是**应急手段**，别当常规退路：

- 本地没有旧镜像（被清理过）就回不去了——**部署前先确认旧镜像还在**。
- 如果本机还留着 v1.x 时代的 `<仓库>:prev` 标签，也可以直接拿它当旧镜像（`docker tag <仓库>:prev <仓库>:latest` 再重建），但脚本不会再移动或维护这个标签。
- 长远做法是**先在一个测试项目上演练**：确认新版本没问题，再让同样的流程作用到生产。

### 两种模式的回滚能力对照

| 模式 | 回滚点 | 怎么回 | 退出码 2 会出现在哪 |
|---|---|---|---|
| 容器模式 | DPanel 备份容器 `<容器名>-bak-<时间戳>`（跑旧镜像、`Exited`） | DPanel 网页恢复 / 改名；或 `docker stop` + `rm` 新容器 → `docker rename` 备份 → `docker start` | 不会出现：回滚由 DPanel 负责，脚本不感知 |
| Compose 模式 | **没有**（不生成备份容器，也不维护 `:prev`） | `docker tag <旧镜像ID> <仓库>:latest` → `docker compose up -d --force-recreate` | 不会出现：拉取失败时脚本根本不部署 |

## 6. 排查升级前的残留

脚本**自己不再产生**互斥锁文件，也不再产生 `/tmp/.container-autoupdate/compose-*` / `plain-*` 事务目录。但**升级前的残留还在**：v1.x 的锁文件、没退干净的拉取进程、事务目录都留在原地。

仓库里带了一个**只读**排查脚本 `scripts/ct-stale-lock-check.sh`：它不改任何东西、不杀任何进程，只把下面这些列出来，末尾给出可复制的清理命令。
用法不变——它检查的本来就是 v1.x 时代留下的锁文件与残留拉取进程，与脚本现在走哪条更新路径无关：

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
# 1) 旧的锁文件（脚本已不使用锁，留着只是垃圾）
rm -f /tmp/.container-autoupdate/*.lock

# 2) 残留的拉取进程：先看它的命令行，确认是残留再 kill
cat /proc/<PID>/cmdline | tr '\0' ' '
kill <PID>

# 3) v1.x 残留的事务目录（先看里面的日志，确认问题已解决）
rm -rf /tmp/.container-autoupdate/compose-<项目名>
```

`compat/` 目录建议保留：那是跨版本提示的记录（`COMPAT_ROOT`），删掉只会在下次升级时多提示一次。

## 7. 常见问题

**Q：容器模式报 `ERR DPanel 检查失败`，怎么办？**
A：脚本已经把 DPanel 的原始错误文本透传在冒号后面，先看那句话。最常见两种：容器名写错了（DPanel 会告诉你找不到这个容器），或者 DPanel CLI 根本调不通。CLI 调不通的形状不一样，是 `ERR 无法调用 DPanel CLI`：

```text
[2026-11-03 06:00:12] ERR 无法调用 DPanel CLI（/app/server/dpanel）
[2026-11-03 06:00:12]     脚本当前环境里没有这个可执行文件

[2026-11-03 06:00:12] ERR 无法调用 DPanel CLI（/app/server/dpanel）
[2026-11-03 06:00:12]     已尝试：docker exec dpanel /app/server/dpanel version
[2026-11-03 06:00:12]     DPanel 容器名不是 dpanel 时用 --dpanel-container 指定，路径不同用 --dpanel-bin
```

→ ERR: cannot call the DPanel CLI (/app/server/dpanel)
→     this environment does not have that executable
→ ERR: cannot call the DPanel CLI (/app/server/dpanel)
→     tried: docker exec dpanel /app/server/dpanel version
→     when the DPanel container is not named dpanel use --dpanel-container; a different path needs --dpanel-bin

两种形状对应两种修法：在 dpanel 容器内跑时 `/app/server/dpanel` 必须是可执行文件（用 `--dpanel-bin` 改路径）；在别处跑时用 `--dpanel-container` 指定容器名、`--dpanel-bin` 指定容器内路径。

**Q：Compose 报「找不到 Compose 项目 X 的项目目录」，怎么办？**
A：脚本先按容器标签反查项目目录，反查不到（这个项目**一个容器都没有**，比如还没部署过）才报这个错。加 `--compose-dir` 指路：

```text
[2026-11-03 06:00:12] ERR 找不到 Compose 项目 myapp 的项目目录
[2026-11-03 06:00:12]     当前 Docker 里没有带「myapp」这个 compose 项目标签的容器，反查不到
[2026-11-03 06:00:12]     处理方式二选一：
[2026-11-03 06:00:12]       1) 用 --compose-dir <路径> 指定 compose 文件所在目录
[2026-11-03 06:00:12]       2) 确认项目名写法；项目还没部署过就先手动 compose up 一次
```

→ ERR: cannot find the project directory of Compose project myapp
→     no container in Docker carries the "myapp" compose project label, so it cannot be looked up
→     two ways to fix it:
→       1) use --compose-dir <path> to point at the directory holding the compose file
→       2) check the project name; and if the project has never been deployed, run compose up once by hand

三条路选一条：写成 `--compose-dir /opt/myapp`（或设 `COMPOSE_DIR`）；核对 `--compose` 的项目名拼写；或者这个项目确实还没起来过，先手工 `docker compose up -d` 一次，之后容器标签就能反查到了。
另一种相邻的错是目录**存在性是假**：`ERR Compose 项目目录不存在：<路径>`——目录被删了或路径写错了，同样退出码 `1`。

**Q：Compose 报「有容器没在运行」，怎么办？**
A：`docker compose up -d` 本身成功了，但脚本发现这个项目里有容器不是 running（`exited` / `restarting` / `dead` 都会点出来），于是如实报错、退出码 `1`。按提示去看那个服务的日志：

```sh
docker compose logs <服务名>        # 在项目目录里跑
```

**Q：`OK Compose 项目 X 已是最新` 和「已重新部署 / 已部署（新建）」差在哪？**
A：这是三种不同的事实，脚本分开报：

| 日志 | 事实 |
|---|---|
| `OK Compose 项目 X 已是最新（拉取后没有容器需要重建）` | `docker compose pull` 成功，但拉取后**没有任何容器需要重建**——镜像没变，`up -d` 是空操作。这是「拉取本身就是判断」得出的结论，不是提前预测 |
| `OK Compose 项目 X 已重新部署（N/M 个容器换了镜像）` | 有容器换了镜像：逐个打了 `已重建：<名>（旧12位 → 新12位）` |
| `OK Compose 项目 X 已部署（K 个容器新建）` | 部署前没有这些容器（首次部署，或 compose 文件里新加的服务）：逐个打了 `新建：<名>（新12位）` |

Compose 模式**没有「只检查有没有新版本」这种能力**：判断只能靠 `docker compose pull` 本身。`--dry-run` 也不做检查，它只是把项目涉及的镜像列出来就退出 0：

```text
[2026-11-03 06:00:12] DRY 只检查不动手：上面是这个项目涉及的镜像，本轮不拉取、不部署
[2026-11-03 06:00:12]     要真正更新就去掉 --dry-run（拉取本身就是「有没有新版本」的判断）
```

→ DRY: check only, no action: those are the images involved in this project; nothing is pulled or deployed this round
→     to actually update, drop --dry-run (the pull itself is what decides whether there is a new version)

（容器模式的 `--dry-run` 含义不同：它会真的去问 DPanel，报「发现新版本」但不升级。）

**Q：日志说 `WARN 剩余时间不足（…），本轮不部署，项目保持原样`，是坏了吗？**
A：不是。这一轮剩下的预算已经低于 `DP_MIN_UPGRADE`（默认 90 秒），脚本**主动不动手**，免得做到一半被计划任务 SIGKILL（那一轮日志里什么都留不下），退出码 `1`。下一轮计划任务会重新判断。长期出现就调大 `T_HARD` 或计划任务的执行超时。

**Q：任务失败，日志是「这个参数已经不能用了：xxx」或「这个环境变量已经不能用了：xxx」，退出码 `3`。**
A：你的启动命令 / 计划任务里还留着旧写法。按日志里的「迁移方式」改；作废清单见[第 4 节](#4-从-v1x-迁移)。别顺手乱加 `--compat`——填错版本会每次运行都硬停（见[第 3 节](#3-兼容机制)）。

**Q：`--compat` 到底写哪个版本？**
A：写你**验证过**的版本。想「先停住、别自己升上来」就写**当前脚本的版本**（`sh container-autoupdate.sh --version`）：本次照样跑，但以后出现更新的破坏性变更就硬停（退出码 `3`）。写一个**比变更版本还旧**的版本是反的——脚本每次都会硬停，因为它判定「你还没验证过这个变更」。

**Q：脚本在宿主上跑，怎么指定 DPanel 容器？**
A：加 `--dpanel-container <容器名>`（默认 `dpanel`）。这时脚本用 `docker exec <容器名> /app/server/dpanel ...` 调用 DPanel，并要求本机有可用的 `docker` 命令（脚本会先 `docker version` 探一下）。DPanel CLI 不在默认路径时用 `--dpanel-bin <路径>`；DPanel 里的 docker 环境名不是 `local` 时用 `--dpanel-docker-env <名字>`。

**Q：计划任务跑到一半被杀，退出码 `143`。**
A：DPanel 的「执行超时」到了。三件事一起看：DPanel 执行超时（设 ≥ 600 秒）、脚本整轮硬上限 `T_HARD`（默认 540 秒）、单次调用超时（`DP_T_UPGRADE` 默认 420 秒、`DP_T_PULL` 默认 420 秒、`DP_T_UP` 默认 180 秒，实际还会按剩余预算收敛）。**内部超时必须明显小于外部超时**，否则被 SIGKILL 的那一轮日志里可能只剩 `signal: killed`。

**Q：能不能一次更新多个目标？**
A：不能，一个进程一个目标。不同目标可以各自挂一个计划任务；同一目标只挂一个。

**Q：能不能让脚本从多个镜像地址并行取最快的？**
A：不需要。Compose 模式的拉取由 `docker compose pull` 完成，用的是你和 daemon 配置的镜像源；容器模式的拉取由 DPanel 负责。脚本根本不碰 Registry。这个想法历史上评估过，未实施。
