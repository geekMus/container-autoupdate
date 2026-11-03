# container-autoupdate

> 语言：[中文](README.md) | [English](README.en.md)

**DPanel 计划任务**用的容器自动更新脚本，单文件。

跑一次 = 检查一次：脚本只做「判断该不该更新 → 执行更新动作 → 如实报出结果」这三件事。**脚本不含调度**，频率、启停、并发全交给 DPanel 的「计划任务」。

> 两条路各用各的长处：**普通容器交给 DPanel**，**Compose 项目交给 docker 自己的 compose 命令**。容器重建要准确复刻网络、挂载（含匿名卷的真实名字）、资源限制、重启策略、Capabilities……漏一处就是生产事故，而 DPanel 本来就干这件事，升级失败还会自行回滚、留下现成的备份容器；Compose 项目则自带「有哪些容器、用哪个 compose 文件、怎么重建」的全部信息，`docker compose pull` + `docker compose up -d` 就是它的标准做法。脚本因此从 1700 多行降到 700 行左右，逻辑面小、可控。

> 手动运行也允许，那只是「跑一轮就结束」的单次更新。**不建议**再套 cron / systemd timer 之类的时间器——并发交给 DPanel 计划任务保证，同一目标只挂一个计划任务。

## 两种模式

| 你的容器是怎么起的 | 用哪个参数 | 脚本实际执行 |
|---|---|---|
| `docker compose up -d` | `--compose <项目名>` | `docker compose pull` + `docker compose up -d`（就地重新部署） |
| `docker run ...` | `--container <容器名>` | `dpanel container:upgrade --name <容器名>`（先只检查，确认有新版本才加 `--upgrade` 升级） |

**容器模式**只把目标名字交给 DPanel，别的什么都不做。

**Compose 模式**不经过 DPanel，先在 Docker 里认这个项目：用
`docker ps -a --filter label=com.docker.compose.project=<项目名>` 找到项目里的容器，再读它身上的三个 compose 标签——
`com.docker.compose.project.working_dir`（工作目录）、`com.docker.compose.project.config_files`（compose 文件）、
`com.docker.compose.project.environment_file`（env 文件）。反查不到时（项目里连一个容器都没有）才用 `--compose-dir <路径>` 兜底
（**从 v2.1.0 起恢复可用**）。拿到目录后，在那个目录里跑 compose 自己的 `pull` 与 `up -d`，再把「哪些容器换了镜像、有没有容器起不来」如实报出来。

> 为什么 Compose 不走 DPanel：**项目不需要先在 DPanel 网页里登记**，也不用管 `compose:deploy` 的 `--pull-image`
> 默认值那个坑（默认值 `command` 不会去拉新镜像，结果是「部署成功但版本没变」）。脚本只用 `docker compose pull` +
> `docker compose up -d`，**不加 `--remove-orphans`**——它会删掉不在当前 compose 文件里的容器，属于数据事故。

> 镜像（Registry）的拉取全部交给 Docker daemon / DPanel，用的是**你和 daemon 配置的镜像源**，脚本根本不碰 Registry —— 所以「多镜像地址并行竞速」这件事不再需要。

## 前置条件

- **容器模式**需要目标机器上装了 **DPanel**：升级动作靠 DPanel 自己的命令行（DPanel 1.11.x 自带的 `container:upgrade`）。
- **推荐在 dpanel 容器里跑**：DPanel 的「计划任务」默认就是在 dpanel 容器内执行，脚本直接调用 `/app/server/dpanel`。
- 容器模式在宿主上跑也行，但需要宿主有 `docker` 命令：脚本会改用 `docker exec dpanel /app/server/dpanel ...` 进容器调用。DPanel 容器名不叫 `dpanel` 时用 `--dpanel-container <名字>` 指定。
- **Compose 模式不依赖 DPanel**：它需要 `docker` 与 **Compose v2 插件**（`docker compose`，不是 `docker-compose`）；插件不可用时打 `ERR 无法执行 docker compose（缺 compose 插件？）`，退出码 `1`。
- **Compose 项目不需要在 DPanel 网页里登记**：脚本按项目名从容器标签反查项目目录与 compose 文件；反查不到时用 `--compose-dir <路径>` 指定，或者先手动 `docker compose up -d` 一次，让标签落到容器上。
- 依赖命令：`timeout` `sed` `awk` `grep`（busybox / coreutils 都行）。Compose 模式、以及不在 dpanel 容器内跑的时候，额外需要 `docker`。主脚本**不需要 `curl`、`flock`**（引导器仍需 `curl` 下载脚本）。

## 快速开始

### DPanel 计划任务

新建计划任务，脚本框里填**两行**：

```sh
# 引导器会自己缓存脚本：第一次下载，之后同版本直接复用，不必每轮都联网
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

普通容器把最后一段换成 `--container mycontainer`。

> 下载地址里的 `https://github.mus.pp.ua/` 是自建加速前缀，不想要就去掉它（直连 GitHub）。前缀坏了就换 `https://gh-proxy.com/`——引导器自己会按「自建站 → gh-proxy → 直连」的顺序逐个试。
>
> 执行超时请设 **≥ 600 秒**（脚本自身的硬上限是 540 秒）。
>
> **为什么不推荐 `curl ... | sh`**：管道写法在下载失败时会**静默成功**（任务日志看不出这轮没跑成）。引导器会把下载落到文件、校验通过才执行，失败时明确返回非 0。
>
> **生产环境建议锁版本**：给引导器加 `--ct-version <版本号>`（或设 `CT_VERSION`；版本号见 [Releases](https://github.com/geekMus/container-autoupdate/releases)），它就不再探测远端、永不联网取新版本。用 `latest` 也没关系——真遇到破坏性变更，脚本会自己停下并在日志里写清原因和改法。

### 手动跑一轮

想临时检查一次，直接跑就行（跑完就结束，不会常驻）。引导器第一次要先落地到本地：

```sh
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

> 不建议用 cron / systemd timer 来定时跑：同一个目标同时跑两轮会互相踩。要定时更新就用 DPanel 计划任务——同一目标只挂一个计划任务即可。

## 引导器怎么工作

| 模式 | 行为 | 网络开销 |
|---|---|---|
| 固定版本（`--ct-version <版本号>` / `CT_VERSION`） | 本地有就直接跑 | **零**（完全不联网） |
| `latest`（默认），本地同版本 | 只探测远端版本号，不下载 | 一次 Range 请求（取文件头 16KB，约 1 秒） |
| `latest`，远端更新 | 下载新版本并缓存，再执行 | 一次探测 + 一次完整下载（约 80KB） |
| 探测失败但本地有缓存 | 用缓存继续跑，只打 `WARN` | 零 |
| 探测失败且无缓存 | **明确报错退出**（不会静默成功） | 零 |

缓存放在 `/var/cache/container-autoupdate`（可用 `--ct-cache-dir` / `CT_CACHE_DIR` 改），按版本分文件，只保留最近 3 个（`--ct-cache-keep` / `CT_CACHE_KEEP`）。缓存文件会做语法 + 版本号 + 特征字符串校验，半截文件不会被当成脚本执行。引导器自己的开关一律用 `--ct-*` 前缀（也可用同名 `CT_*` 环境变量；命令行优先），其余参数原样交给主脚本。

## 常用命令

```sh
container-autoupdate.sh --container mycontainer --dry-run   # 容器模式：只问 DPanel 有没有新版本，不动手
container-autoupdate.sh --container mycontainer             # 升级一个普通容器
container-autoupdate.sh --compose myapp                     # 就地重新部署一个 Compose 项目（不需要 DPanel 登记）
container-autoupdate.sh --compose myapp --compose-dir /opt/myapp   # 反查不到项目目录时显式指定
container-autoupdate.sh --dpanel-container mydpanel --container mycontainer   # DPanel 容器不叫 dpanel 时
```

**`--dry-run` 在两种模式下不一样：**

- **容器模式**：真的去问 DPanel 有没有新版本，但不执行升级。有新版本时报「发现新版本」，没有时报「已是最新」：

```text
[2026-11-03 06:00:12] 发现新版本（远端 digest=sha256:a5c10db1...）
[2026-11-03 06:00:12] DRY 只检查不动手，本轮不升级
```

- **Compose 模式**：只列出这个项目涉及的镜像，然后退出 `0`，**不拉取、不部署**。Compose 没有「只检查有没有新版本」这种能力——拉取本身就是判断：

```text
[2026-11-03 06:00:12] MODE compose 项目=myapp
[2026-11-03 06:00:12]     目录=/opt/myapp
[2026-11-03 06:00:12]     文件=/opt/myapp/compose.yaml
[2026-11-03 06:00:12]     镜像: ghcr.1ms.run/yetone/magpie:latest
[2026-11-03 06:00:12] DRY 只检查不动手：上面是这个项目涉及的镜像，本轮不拉取、不部署
[2026-11-03 06:00:12]     要真正更新就去掉 --dry-run（拉取本身就是「有没有新版本」的判断）
```

要在 Compose 项目上预演，只能像这样先看一遍镜像清单，或者挑个测试项目真跑一轮。

> **计划任务里失败时能直接看到原因**：失败原因除了在完整日志里，还会额外写一份到 stderr。
> 计划任务在任务失败时只保留 stderr，早期版本因为只写 stdout，任务里只剩一句 `exit status 1`，什么都排查不出来。

## 回滚

容器模式和 Compose 模式的回滚点不一样，这点必须分清。

**容器模式**：回滚点是 DPanel 生成的**备份容器**，名字形如 `<容器名>-bak-<时间戳>`（例如 `myapp-bak-20261103163808`）。
它跑着升级前的镜像、处于 `Exited` 状态，在 DPanel 网页里能直接看到。命令行回滚：

```sh
docker stop <容器名> && docker rm <容器名>
docker rename <容器名>-bak-<时间戳> <容器名>
docker start <容器名>
```

**Compose 模式**：**没有备份容器，也不维护 `<repo>:prev`**。好在这里的 `docker compose pull` 只拉取、不删旧镜像，
旧镜像还在本地；上一轮日志里的 `已重建：<名>（旧12位 → 新12位）` 就写明了新旧两个镜像 id。
应急做法是把旧镜像重新打成 `<repo>:latest`，再强制重建：

```sh
docker tag <旧镜像ID> <repo>:latest
docker compose up -d --force-recreate
```

> 想更稳妥，升级前先记下容器当前用的镜像 ID（`docker inspect -f '{{.Image}}' <容器名>`），免得事后翻日志。

## 版本与升级

地址用 `releases/latest/download/`，**不含版本号，永远指向最新发布版**，直接复制粘贴即可。

脚本自身的版本号在日志和 `--version` 里能看到：

```sh
sh container-autoupdate.sh --version    # 例如 1.2.3
```

发布新版本由仓库的 GitHub Actions 自动完成：只要脚本里的 `VERSION` 字段变成一个新值并推到 `main`，工作流就会自动打 tag 并发布 Release（详见 [进阶用法](docs/advanced-usage.md)）。

想**锁定某个版本**（不让它跟着最新版走），给引导器加 `--ct-version`：

```sh
/usr/local/bin/ct-bootstrap.sh --ct-version 1.2.3 --compose myapp
# 旧写法仍可用：CT_VERSION=1.2.3 /usr/local/bin/ct-bootstrap.sh --compose myapp
```

锁版本时引导器完全不联网，对生产环境最稳。tag 号见 [Releases](https://github.com/geekMus/container-autoupdate/releases)。

### 升级到 v2.x 要注意什么

v2.0.0 起脚本不再自己实现「拉镜像 / 重建容器」，更新动作改由 DPanel（容器模式）与 docker 自己的 compose 命令（Compose 模式）执行；脚本也不再维护 `:prev` 回滚点、状态目录和坏版本钉住。如果你是从更早的版本升上来的，先看清下面几条。

**三个参数作废**（传了会立即中止，退出码 `3`，日志里给迁移说明）：

- `--state-dir`：脚本不再维护状态目录，跨版本提示的记录改到 `COMPAT_ROOT`（默认 `/tmp/.container-autoupdate/compat`）。
- `--bad-ttl-days`：不再有「坏版本钉住」，回滚由 DPanel 负责。
- `--pull-retries`：容器模式的拉取由 DPanel 完成，Compose 模式的拉取由 `docker compose pull` 完成，脚本不再管理拉取与重试。

> `--compose-dir` **不是作废项**：从 v2.1.0 起它恢复可用，用来在反查不到项目目录时兜底。

**一批环境变量同样作废**（设置了就会命中中止）：`STATE_ROOT`、`BAD_TTL_DAYS`、`PULL_RETRIES`、`DIGEST_RETRIES`、`DIGEST_RETRY_WAIT`、`T_STALL`、`T_STALL_FINISH`、`T_PULL_MAX`、`T_UP`、`T_HEALTH`、`HEALTH_TRIES`、`T_ROLLBACK`、`PLAIN_BOOT`、`COMPOSE_BASE`、`LOCK_PREFIX`（完整清单见 [全部参数与环境变量](docs/parameters.md)）。删掉它们即可，不需要任何替代设置。

> 两个例外：`T_INSPECT` 是 `DP_T_CHECK` 的旧名字，**仍然接受**；`COMPOSE_DIR` 从 v2.1.0 起恢复可用，等价于 `--compose-dir`。

其他要注意的：

- **`LOCK_PREFIX` 会被当成破坏性变更**：脚本内部不再加互斥锁（并发交给 DPanel 计划任务保证），启动命令里还留着 `LOCK_PREFIX=...` 就会直接中止（退出码 `3`）并给出提示。删掉它。
- **Compose 模式不再需要 DPanel 登记**，改为需要 `docker` 与 Compose v2 插件；项目目录默认从容器标签反查，反查不到用 `--compose-dir` 兜底。
- 主脚本不再需要 `curl` 与 `flock`；`--pull-retries` 之类的拉取控制全部作废——容器模式的拉取由 DPanel 负责，Compose 模式的拉取由 `docker compose pull` 负责。

### 排查残留进程和旧锁文件

旧版本反复打出「SKIP 同一更新目标（xxx）的另一个任务仍在执行」时，说明有上一轮没退干净的进程还占着锁。
仓库里带了一个**只读**排查脚本：它只把问题列出来（旧锁文件、占着锁的进程、残留的拉取进程、残留的事务目录），
不改任何东西、不杀任何进程，末尾给出可复制的清理命令，由你确认后自己执行。

```sh
curl -fsSL -L https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh \
  -o /tmp/ct-stale-lock-check.sh
sh /tmp/ct-stale-lock-check.sh
```

> v2.0.0 起，脚本**不再产生锁文件，也不再产生 `/tmp/.container-autoupdate/compose-*` 事务目录**（`:prev` 之类的旧回滚标签也不再生成了）。这个脚本仍然有用：升级前留下来的历史残留还是那副样子，用它排查、清掉即可。
>
> 要在**跑更新的那个环境里**跑它（用 DPanel 的话就是 dpanel 容器内部），因为它要看的是那台机器的 `/proc`：
> `docker exec -it dpanel sh /tmp/ct-stale-lock-check.sh`。
>
> 详细的清理步骤见 [进阶用法](docs/advanced-usage.md#6-排查升级前的残留)。

### 用 latest 也安全

上游发新版会直接作用到你机器上。如果新版改坏了你的调用方式（比如某个参数被改名或移除），脚本不会静默忽略，而是**立刻停下**、退出码 `3`，并在日志里写清三件事：哪个写法不能用了、从哪个版本起改成了什么、以及怎么改。

```text
[2026-11-01 03:47:12] ERR 这个参数已经不能用了：--oldflag
[2026-11-01 03:47:12]     从 v1.0.0 起改为：--newflag
[2026-11-01 03:47:12]     原因：……
[2026-11-01 03:47:12]     迁移方式：把 --oldflag 换成 --newflag
[2026-11-01 03:47:12]     或者把下载地址固定到旧版本（见 README「版本与升级」）
[2026-11-01 03:47:12]     本次未做任何改动，退出码 3
```

对于**没法自动识别**的变化（比如某个默认行为改了），脚本用两种方式兜住：

- **跨版本提示**：它会记住每个目标上次跑过的版本。升级到含破坏性变更的新版时，日志里会多一段 `WARN`，说明改了什么、该怎么应对，然后照常执行。
- **`--compat <版本>`**：你可以声明「我只验证到某个版本」。如果脚本比这个版本新、且中间有破坏性变更，它会硬停而不是冒险执行。

```sh
container-autoupdate.sh --compose myapp --compat 1.2.3
```

## 更多文档

- [全部参数与环境变量](docs/parameters.md) —— 每个参数是干什么的、什么时候该配
- [进阶用法](docs/advanced-usage.md) —— 下载脚本的坑、退出码、DPanel 注意事项
- [工作方式与安全边界](docs/how-it-works.md) —— 它怎么更新、什么情况会跳过、哪些保护不了

## 许可证

MIT
