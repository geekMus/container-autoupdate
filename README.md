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
URL=https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/container-autoupdate/v0.1.0/container-autoupdate.sh
curl -fsSL $URL | sh -s -- --compose myapp
```

普通容器把最后一段换成 `--container mycontainer`。

> 执行超时请设 **≥ 600 秒**。
>
> 这种管道写法在**下载失败时会静默成功**（任务日志看不出这轮没跑成）。要失败可见，用[进阶用法](docs/advanced-usage.md)里的临时文件写法。

### cron

先下载脚本：

```sh
curl -fsSL https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/container-autoupdate/v0.1.0/container-autoupdate.sh \
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

## 更多文档

- [全部参数与环境变量](docs/parameters.md) —— 每个参数是干什么的、什么时候该配
- [进阶用法](docs/advanced-usage.md) —— 下载脚本的坑、退出码、DPanel 注意事项
- [工作方式与安全边界](docs/how-it-works.md) —— 它怎么更新、什么情况会跳过、哪些保护不了

## 许可证

MIT
