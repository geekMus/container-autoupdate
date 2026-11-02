# container-autoupdate

> 语言：[中文](README.md) | [English](README.en.md)

**DPanel 定时任务**用的容器自动更新脚本，单文件。

跑一次 = 检查一次：有新版本就更新并验证，没有就立刻退出。**脚本不含调度**，频率、启停、并发全交给 DPanel 的「计划任务」。

> 手动运行也允许，那只是「跑一轮就结束」的单次更新。**不建议**再套 cron / systemd timer 之类的时间器——脚本内部不再加互斥锁，同一个目标同时跑两轮会互相踩。

## 两种模式

| 你的容器是怎么起的 | 用哪个参数 |
|---|---|
| `docker compose up -d` | `--compose <项目名>` |
| `docker run ...` | `--container <容器名>` |

镜像地址不用填，脚本自己从 Compose 文件或容器本身读出来。

## 快速开始

### DPanel 计划任务

新建计划任务，脚本框里填**两行**：

```sh
# 引导器会自己缓存脚本：第一次下载，之后同版本直接复用，不必每轮都联网
curl -fsSL https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

普通容器把最后一段换成 `--container mycontainer`。

> 执行超时请设 **≥ 600 秒**。
>
> **为什么不推荐 `curl ... | sh`**：管道写法在下载失败时会**静默成功**（任务日志看不出这轮没跑成）。引导器会把下载落到文件、校验通过才执行，失败时明确返回非 0。
>
> **生产环境建议锁版本**：给引导器加 `--ct-version <版本号>`（或设 `CT_VERSION`；版本号见 [Releases](https://github.com/geekMus/container-autoupdate/releases)），它就不再探测远端、永不联网取新版本。用 `latest` 也没关系——真遇到破坏性变更，脚本会自己停下并在日志里写清原因和改法。

### 手动跑一轮

想临时检查一次，直接跑就行（跑完就结束，不会常驻）。引导器第一次要先落地到本地：

```sh
curl -fsSL https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /tmp/ct-bootstrap.sh
sh /tmp/ct-bootstrap.sh --compose myapp
```

> 不建议用 cron / systemd timer 来定时跑：脚本内部不再加互斥锁，同一个目标同时跑两轮会互相踩。要定时更新就用 DPanel 计划任务——同一目标只挂一个计划任务即可。

## 引导器怎么工作

| 模式 | 行为 | 网络开销 |
|---|---|---|
| 固定版本（`--ct-version <版本号>` / `CT_VERSION`） | 本地有就直接跑 | **零**（完全不联网） |
| `latest`（默认），本地同版本 | 只探测远端版本号，不下载 | 一次 4KB Range 请求（约 1 秒） |
| `latest`，远端更新 | 下载新版本并缓存，再执行 | 一次探测 + 一次完整下载（约 70KB） |
| 探测失败但本地有缓存 | 用缓存继续跑，只打 `WARN` | 零 |
| 探测失败且无缓存 | **明确报错退出**（不会静默成功） | 零 |

缓存放在 `/var/cache/container-autoupdate`（可用 `--ct-cache-dir` / `CT_CACHE_DIR` 改），按版本分文件，只保留最近 3 个（`--ct-cache-keep` / `CT_CACHE_KEEP`）。缓存文件会做语法 + 版本号 + 特征字符串校验，半截文件不会被当成脚本执行。引导器自己的开关一律用 `--ct-*` 前缀（也可用同名 `CT_*` 环境变量；命令行优先），其余参数原样交给主脚本。


## 常用命令

```sh
container-autoupdate.sh --compose myapp --dry-run    # 只看有没有新版本，不更新、不删镜像
container-autoupdate.sh --compose myapp              # 正式更新 Compose 项目
container-autoupdate.sh --container mycontainer      # 更新普通容器
container-autoupdate.sh --compose myapp --pull-retries 2   # 拉取失败多试一次（默认 1 次）
```

**第一次接入建议先跑 `--dry-run`**，确认日志里认到的目标和目录是对的，再去掉它。
（演练只写状态目录，不动容器、不动镜像标签、也不清理旧镜像。）

拉取失败（网络抖动、镜像源瞬时 5xx）默认**重试 1 次**，两次之间等 10 秒；
`--pull-retries <次数>` 可以改次数，`0` = 不重试。
但**拉取卡死**（60 秒没有任何新字节）和**镜像源明确报错**（镜像不存在、鉴权失败）不重试 —— 重试也不会成功。

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

### 升级到「不再带互斥锁」的版本要注意什么

新版本已经**移除了脚本内部的互斥锁**（`LOCK_PREFIX` 环境变量也随之作废）——
并发改由 DPanel 计划任务保证。

怎么判断你踩没踩到过这个问题：旧版本日志里如果反复出现

```sh
[2026-11-02 19:00:05] SKIP 同一更新目标（compose-myapp）的另一个任务仍在执行，本轮跳过
```

而且**每一轮都一样、什么都没更新**——那说明旧版的锁被一个没退干净的子进程长期占住了。
升级之后这个现象自然消失。

升级后请确认两件事：

1. **同一个目标只挂一个 DPanel 计划任务**（脚本不再帮你挡并发了）。
2. 如果你的启动命令里还留着 `LOCK_PREFIX=...`，删掉它。留着的话脚本会按破坏性变更处理，
   直接中止并给出提示（退出码 `3`），不会静默忽略。

### 排查残留进程和旧锁文件

旧版本反复打出「SKIP 同一更新目标（xxx）的另一个任务仍在执行」时，说明有上一轮没退干净的进程还占着锁。
仓库里带了一个**只读**排查脚本：它只把问题列出来（旧锁文件、占着锁的进程、残留的拉取进程、残留的事务目录），
不改任何东西、不杀任何进程，末尾给出可复制的清理命令，由你确认后自己执行。

```sh
curl -fsSL -L https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh \
  -o /tmp/ct-stale-lock-check.sh
sh /tmp/ct-stale-lock-check.sh
```

> 要在**跑更新的那个环境里**跑它（用 DPanel 的话就是 dpanel 容器内部），因为它要看的是那台机器的 `/proc`：
> `docker exec -it dpanel sh /tmp/ct-stale-lock-check.sh`。
>
> 详细的清理步骤见 [进阶用法](docs/advanced-usage.md#7-排查残留进程与旧锁文件)。

### 用 latest 也安全

上游发新版会直接作用到你机器上。如果新版改坏了你的调用方式（比如某个参数被改名或移除），脚本不会静默忽略，而是**立刻停下**、退出码 `3`，并在日志里写清三件事：哪个写法不能用了、从哪个版本起改成了什么、以及怎么改。

```sh
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
