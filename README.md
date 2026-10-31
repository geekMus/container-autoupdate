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

新建计划任务，脚本框里填：

```sh
URL=https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
curl -fsSL $URL | sh -s -- --compose myapp
```

普通容器把最后一段换成 `--container mycontainer`。

> 执行超时请设 **≥ 600 秒**。
>
> 这种管道写法在**下载失败时会静默成功**（任务日志看不出这轮没跑成）。要失败可见，用[进阶用法](docs/advanced-usage.md)里的临时文件写法。
>
> **生产环境建议锁版本**：把地址里的 `latest/download` 换成具体 tag（见下面「版本与升级」）。用 `latest` 也没关系——真遇到破坏性变更，脚本会自己停下并在日志里写清原因和改法。

### cron

先下载脚本：

```sh
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh \
  -o /usr/local/bin/container-autoupdate.sh && chmod +x /usr/local/bin/container-autoupdate.sh
```

再写进 crontab：

```sh
# 每天 04:00 检查并更新
0 4 * * * /usr/local/bin/container-autoupdate.sh --compose myapp >> /var/log/ct-update.log 2>&1
```

## 常用命令

```sh
container-autoupdate.sh --compose myapp --dry-run    # 只看有没有新版本，不改动
container-autoupdate.sh --compose myapp              # 正式更新 Compose 项目
container-autoupdate.sh --container mycontainer      # 更新普通容器
```

**第一次接入建议先跑 `--dry-run`**，确认日志里认到的目标和目录是对的，再去掉它。

## 版本与升级

上面的地址用 `releases/latest/download/`，**不含版本号，永远指向最新发布版**，直接复制粘贴即可。

脚本自身的版本号在日志和 `--version` 里能看到：

```sh
sh container-autoupdate.sh --version    # 例如 0.2.0
```

发布新版本由仓库的 GitHub Actions 自动完成：只要脚本里的 `VERSION` 字段变成一个新值并推到 `main`，工作流就会自动打 tag 并发布 Release（详见 [进阶用法](docs/advanced-usage.md)）。

想**锁定某个版本**（不让它跟着最新版走），把地址里的 `latest/download` 换成具体 tag：

```sh
https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/download/v0.2.0/container-autoupdate.sh
```

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
container-autoupdate.sh --compose myapp --compat 0.2.0
```

## 更多文档

- [全部参数与环境变量](docs/parameters.md) —— 每个参数是干什么的、什么时候该配
- [进阶用法](docs/advanced-usage.md) —— 下载脚本的坑、退出码、DPanel 注意事项
- [工作方式与安全边界](docs/how-it-works.md) —— 它怎么更新、什么情况会跳过、哪些保护不了

## 许可证

MIT
