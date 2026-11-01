# container-autoupdate

给 Docker 做**容器自动更新**的单文件脚本。

跑一次 = 检查一次：有新版本就更新并验证，没有就立刻退出。**脚本不含调度**，频率交给你的定时器。

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

### cron

用引导器最省事——它负责缓存，你只写一行 crontab：

```sh
# 每天 04:00 检查并更新
0 4 * * * /usr/local/bin/ct-bootstrap.sh --compose myapp >> /var/log/ct-update.log 2>&1
```

先把引导器落地一次（之后它自己维护缓存，不需要再下载）：

```sh
curl -fsSL https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /usr/local/bin/ct-bootstrap.sh && chmod +x /usr/local/bin/ct-bootstrap.sh
```

想锁版本，在 crontab 里加 `--ct-version`（也可用环境变量 `CT_VERSION`）：

```sh
0 4 * * * /usr/local/bin/ct-bootstrap.sh --ct-version <版本号> --compose myapp >> /var/log/ct-update.log 2>&1
```

> 不想用引导器也行：直接把主脚本下载到本地，定时任务跑它即可（见[进阶用法](docs/advanced-usage.md)）。代价是脚本不会自己升级。

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
```

**第一次接入建议先跑 `--dry-run`**，确认日志里认到的目标和目录是对的，再去掉它。
（演练只写状态目录和锁文件，不动容器、不动镜像标签、也不清理旧镜像。）

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
