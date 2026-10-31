# container-autoupdate

一个用于自动更新 Docker 容器 / Compose 项目的单文件 shell 脚本。

**它是「单轮逻辑」**：跑一次，检查一次，该更新就更新，然后退出。频率由你的定时器决定 ——
cron、systemd timer、DPanel 计划任务、CI 都行，脚本本身不含任何调度逻辑。

```sh
# 检查并更新一个 Compose 项目
container-autoupdate.sh --compose myapp

# 检查并更新一个普通容器
container-autoupdate.sh --container mycontainer
```

---

## 它解决什么问题

手动更新一个容器看着简单，实际很容易踩坑：

- 只 `docker pull` + `docker restart` **不会**用上新镜像（容器绑的是创建时的镜像 ID）。
- 重建容器时忘记某个 `--env`、`--dns`、端口映射、卷挂载，配置就悄悄丢了。
- 更新完容器起不来，没有回滚点，只能凭记忆手工救。
- `docker compose up -d` 没加 `--force-recreate` 时，tag 变了但服务定义没变，可能根本不重建。
- 拉取卡住（镜像仓库/代理偶发挂死）时脚本一直挂着，被外部超时 SIGKILL，日志全丢。

这个脚本把上述每一条都当作必须处理的情况，并且**在无法保证安全时选择跳过而不是硬来**。

---

## 特性

| 能力 | 说明 |
|---|---|
| 两种目标 | Compose 项目 或 单个容器，二选一 |
| 镜像自动发现 | 从 Compose 文件 / 容器本身读取，不手工填镜像地址 |
| 保留全部配置 | 容器按声明式字段重建：Env、Cmd、Entrypoint、Labels、Hostname、DNS、端口、卷、网络、资源限制、Restart 策略 |
| 真实回滚 | 健康门禁失败自动回滚，回滚结果经过校验，回滚失败如实报错（不假装成功） |
| 坏版本隔离 | 更新失败的版本钉成 `:bad`，默认 7 天内不再尝试，避免每轮反复踩同一个坏版本 |
| 回滚点 | 成功后把上一版打成 `:prev`，只保留 1 份 |
| 卡死检测 | 拉取流 60 秒无进度即判定卡死并 kill，不靠固定超时 |
| 硬时间预算 | 全脚本 540 秒硬上限，永远能在外部超时前自己收尾 |
| 中断可恢复 | 被 SIGTERM/SIGINT 打断或进程被 kill，下一轮自动按事务状态恢复 |
| 互斥 | 锁按「更新目标」派生：不同目标可并行，同一目标串行 |
| 失败即跳过 | AutoRemove、`container:*` 网络、VolumesFrom、Compose 管理的容器等不安全形态一律跳过并说明原因 |

---

## 安装

脚本无依赖打包，只需要目标机器上有：

```
docker（含 compose 插件，用于 Compose 分支）
curl
flock（util-linux 或 busybox）
timeout（coreutils 或 busybox）
sed / awk / grep
```

下载后加执行权限即可：

```sh
curl -fsSL https://raw.githubusercontent.com/geekMus/container-autoupdate/v6.0.0/container-autoupdate.sh \
  -o /usr/local/bin/container-autoupdate.sh
chmod +x /usr/local/bin/container-autoupdate.sh
```

> **建议固定 tag 而不是跟随 `main`**。这是会自动改动生产容器的脚本，让它的内容随上游分支漂移
> 是没必要的风险。上面的链接用了 `v6.0.0`；`main` 分支是最新开发版。

### 中国大陆访问不了 raw.githubusercontent.com 时

`raw.githubusercontent.com` 的 IP 在国内经常被阻断（表现为 `curl: (28) Connection timed out`，
DNS 却能正常解析）。用下面任一镜像源替换地址前缀即可，内容与 GitHub 完全一致：

```sh
# gh-proxy.com（实测最快）
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/geekMus/container-autoupdate/v6.0.0/container-autoupdate.sh \
  -o /usr/local/bin/container-autoupdate.sh

# ghproxy.net
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/geekMus/container-autoupdate/v6.0.0/container-autoupdate.sh \
  -o /usr/local/bin/container-autoupdate.sh

# jsDelivr（CDN，注意路径格式不同）
curl -fsSL https://cdn.jsdelivr.net/gh/geekMus/container-autoupdate@v6.0.0/container-autoupdate.sh \
  -o /usr/local/bin/container-autoupdate.sh
```

下载后建议核对一下确实是官方内容：

```sh
sh /usr/local/bin/container-autoupdate.sh --version   # 应输出 6.0.0
```

### 在容器里跑的情况

如果定时任务是在**容器内**执行（比如 DPanel 的计划任务），下载到容器里会随容器重建丢失。
把脚本放到宿主机的**挂载目录**里更稳妥，容器和宿主机都能访问同一个文件：

```sh
# 宿主机上：DPanel 的 /root/dpanel 挂载为容器内的 /dpanel
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/geekMus/container-autoupdate/v6.0.0/container-autoupdate.sh \
  -o /root/dpanel/container-autoupdate.sh
```

之后容器内用 `/dpanel/container-autoupdate.sh` 调用，宿主机用 `/root/dpanel/container-autoupdate.sh`。

也可以用 `curl | sh` 直接跑（脚本不读取自身路径，无需落地）：

```sh
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/geekMus/container-autoupdate/v6.0.0/container-autoupdate.sh \
  | sh -s -- --compose myapp --dry-run
```

> `curl | sh` 每次执行都会重新下载，**受网络影响**。定时任务里更推荐落地成文件再调用，
> 避免某次网络抖动导致整轮更新失败。

---

## 用法

```
container-autoupdate.sh --compose <项目名>     更新一个 Compose 项目
container-autoupdate.sh --container <容器名>   更新一个普通容器
container-autoupdate.sh --help                 显示帮助
```

### 选项

| 选项 | 说明 |
|---|---|
| `--compose <名>` | Compose 项目名（`docker compose` 的 project name） |
| `--container <名>` | 容器名 |
| `--compose-dir <目录>` | Compose 项目目录；默认从容器 label 自动发现 |
| `--docker-sock <路径>` | Docker socket；默认读 `DOCKER_HOST` 或 `/var/run/docker.sock` |
| `--state-dir <目录>` | 事务状态目录，默认 `/tmp/.ct-v6` |
| `--bad-ttl-days <天>` | 失败版本钉住多少天后自动解除，默认 7 |
| `--dry-run` | 只检查有没有新版本，不做任何改动 |
| `-h, --help` | 显示帮助 |
| `-V, --version` | 显示版本 |

### 三种指定目标的方式

优先级：**命令行 > 环境变量 > 文件顶部配置区**。

```sh
# 1. 命令行
container-autoupdate.sh --compose myapp

# 2. 环境变量
UPD_COMPOSE=myapp container-autoupdate.sh
UPD_CONTAINER=mycontainer container-autoupdate.sh

# 3. 改脚本顶部配置区（适合把脚本当成固定用途来用）
COMPOSE_NAME="myapp"
CONTAINER_NAME=""
```

### 环境变量

| 变量 | 说明 |
|---|---|
| `UPD_COMPOSE` / `UPD_CONTAINER` | 目标（同命令行） |
| `COMPOSE_DIR` | 同 `--compose-dir` |
| `COMPOSE_BASE` | Compose 目录回退根路径；留空则只用容器 label 发现 |
| `DOCKER_SOCK` | 同 `--docker-sock` |
| `DOCKER_HOST` | 支持 `unix:///path` 与 `tcp://host:port` |
| `DRY_RUN=1` | 同 `--dry-run` |
| `BAD_TTL_DAYS` | 同 `--bad-ttl-days` |
| `STATE_ROOT` | 同 `--state-dir` |
| `T_HARD` / `T_STALL` / `T_PULL_MAX` / `T_UP` / `T_HEALTH` / `T_ROLLBACK` | 各阶段超时（秒），一般不用改 |

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功，或无需更新，或按规则跳过 |
| 1 | 配置/环境错误，或本轮未能完成更新（容器保持原样） |
| 2 | 回滚本身失败，需要人工介入（现场保留在 `--state-dir`） |

---

## 定时执行

### cron

```sh
# 每天 04:00 检查并更新
0 4 * * * /usr/local/bin/container-autoupdate.sh --compose myapp >> /var/log/ct-update.log 2>&1
```

### systemd timer

`/etc/systemd/system/ct-update.service`：

```ini
[Unit]
Description=Container auto update

[Service]
Type=oneshot
ExecStart=/usr/local/bin/container-autoupdate.sh --compose myapp
```

`/etc/systemd/system/ct-update.timer`：

```ini
[Unit]
Description=Daily container auto update

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

```sh
systemctl enable --now ct-update.timer
```

### DPanel 计划任务

DPanel 的计划任务原生支持环境变量，三种方式都能用。**推荐第 1 种**（脚本落地成文件再调用），
因为它不依赖每次执行时的网络：

**1. 脚本落地 + 命令行参数（推荐）**

把脚本放到宿主机 DPanel 数据目录（该目录挂载为容器内 `/dpanel`）：

```sh
# 宿主机上执行
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/geekMus/container-autoupdate/v6.0.0/container-autoupdate.sh \
  -o /root/dpanel/container-autoupdate.sh
```

然后在 DPanel 任务脚本框里只写一行：

```sh
sh /dpanel/container-autoupdate.sh --compose myapp
```

或者用普通容器：

```sh
sh /dpanel/container-autoupdate.sh --container mycontainer
```

**2. 环境变量面板**

在任务的 Environment 里加一行 `UPD_COMPOSE=myapp`（或 `UPD_CONTAINER=mycontainer`），
任务脚本框里写：

```sh
sh /dpanel/container-autoupdate.sh
```

> 环境变量的值会被 DPanel 做一次 `os.Expand` 展开，**值里不要带 `$`**。

**3. 脚本全文粘进任务**

把脚本全文粘进任务脚本框，在顶部配置区填 `COMPOSE_NAME="myapp"`。
这种方式最自包含，但每次更新脚本都要重新粘贴，且任务配置里存一份副本。

> **两个必须注意的点：**
>
> - **执行超时要设 ≥ 600 秒**。脚本自身硬上限 540 秒，留出余量才能保证它自己收尾而不是被外部 SIGKILL（被外部杀掉时日志会全部丢失）。
> - **在 UI 里改过任务排期后，回来确认 `scriptRunTimeout` 还在**。DPanel 重写任务配置时会丢掉这个字段（`omitempty`，缺省为 0 即不限时），需要重新设置。

**建议第一次先试运行**：把任务脚本临时改成 `sh /dpanel/container-autoupdate.sh --compose myapp --dry-run`，
手动跑一次看日志确认目标识别正确，再改回正式命令并启用定时。

---

## 安全边界

这个脚本尽量保守，但它**不是万能的**，以下情况请了解：

### 会主动跳过的情况

| 情况 | 原因 |
|---|---|
| 容器 `AutoRemove=true` | 停止旧容器会直接删掉它，没有回滚副本 |
| `NetworkMode=container:*` | 共享其它容器的网络栈，重建会断链 |
| 有容器依赖它的网络或 legacy link | 同上，重建期间依赖方会断 |
| 使用 `VolumesFrom` | 挂载来源是另一个容器，重建后语义不明 |
| 由 Compose 管理的容器，但你用 `--container` 指定 | 请改用 `--compose`，否则会破坏 Compose 的状态 |
| 镜像引用是 digest 形式（`repo@sha256:…`） | 无法判断「有没有新版本」 |
| bind 挂载带 SELinux `Mode=z` | 重建时标签语义可能变化 |
| 容器当前不是 running | 不去动它 |
| Compose 项目里没有容器 | 不执行首次部署 |
| Compose 项目里同一镜像的运行版本不一致 | 说明有人手工干预过，先不自动处理 |

### 无法保护的东西

- **数据不会回滚。** 回滚恢复的是容器和镜像，新版本程序如果已经改过数据库结构、迁移过文件，回滚镜像不会撤销这些改动。**生产数据库请自行备份。**
- **匿名卷的数据**：脚本会复用同名卷（不会换新卷），但容器内的临时写入仍按容器生命周期。
- **`tmpfs` 挂载的内容**在重建后必然清空（这是 tmpfs 的语义，与手动重建一致），脚本会 WARN 提示。
- **私有仓库**：镜像拉取走 Docker Engine API，需要匿名可拉取。需要认证的私有仓库会安全中止（不会带着半拉的状态继续）。

---

## 工作方式

### Compose 分支

```
1. 从容器 label 发现项目目录（或 --compose-dir 指定）
2. 用 docker compose config --images 拿到镜像清单
3. 逐个对比远端 digest 与容器实际运行的镜像
4. 暂存当前镜像为 <repo>:rollback-pending（不动 :prev）
5. 通过 Docker Engine API 拉取（带字节级进度，60s 无增长判卡死）
6. 校验拉到的 digest 与拉取流报告的 digest 一致
7. docker compose -p <项目> up -d --force-recreate（保留 config/env 文件，不加 --remove-orphans）
8. 确认容器真的运行在新镜像上
9. 健康门禁（有 healthcheck 等 healthy，无则观察 30s 稳定）
10. 成功 → :prev 移到上一版；失败 → 回滚 + 钉 :bad
```

### 容器分支

```
1. 读取容器全部声明式配置（Config + HostConfig + 网络）
2. 检查是否有不能安全处理的形态（见上表）
3. 对比远端 digest 与容器运行的镜像
4. 暂存 + 拉取（同上）
5. 生成重建请求：显式 Mounts（含匿名卷真实名称）、声明式网络配置
6. 旧容器改名 <名>__old_<时间戳>（不中断）→ 停旧 → 建新
7. 启动前做完整规格校验（Config + HostConfig + 挂载 + 网络逐项比对）
8. 启动 → 健康门禁 → 再校验一次实际状态
9. 成功 → 打 :prev、清理更早的 __old_*；失败 → 恢复旧容器与原名称
```

事务状态写在 `--state-dir` 里，被中断后下一轮会自动按阶段恢复（要么还原 tag，要么回滚容器）。

---

## 已知限制

- 需要 Docker Engine API 可访问（`/var/run/docker.sock` 或 TCP）。Podman 的 Docker 兼容层未测试。
- 需要 `docker compose` 插件（v2）。老的 `docker-compose` v1 未测试。
- Compose 项目路径不能含空白字符（安全解析限制，会明确报错）。
- 不支持一次更新多个目标；请为每个目标建一个定时任务（不同目标之间锁是独立的，可以并行）。
- 只支持 Linux（依赖 `flock`、`/proc` 语义）。

---

## 许可证

MIT
