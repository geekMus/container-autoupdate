# 进阶用法

> 基础用法看 [README](../README.md)。这里讲的是**下载方式、退出码、定时器细节，以及几个容易踩的坑**。

## 1. 怎么把脚本弄到机器上

三种方式，按可靠性从高到低。

### 推荐：先下载到文件，再执行

```sh
curl -fsSL https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/container-autoupdate/v0.1.0/container-autoupdate.sh \
  -o /usr/local/bin/container-autoupdate.sh
chmod +x /usr/local/bin/container-autoupdate.sh
/usr/local/bin/container-autoupdate.sh --compose myapp
```

好处：下载失败会明确报错并返回非 0 退出码，定时任务能看出这轮没跑成。

### 次选：先落到临时文件，再执行（不污染磁盘）

```sh
URL=https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/container-autoupdate/v0.1.0/container-autoupdate.sh
_t=$(mktemp)
if curl -fsSL --max-time 60 "$URL" -o "$_t"; then
  sh "$_t" --compose myapp
else
  echo "下载失败" >&2; rm -f "$_t"; exit 1
fi
rm -f "$_t"
```

这是 DPanel 计划任务里最稳的写法：下载失败时 `exit 1` 会出现在任务日志里，而不是静默当成成功。

### 可以：直接管道执行

```sh
curl -fsSL "$URL" | sh -s -- --compose myapp
```

能跑，但有两个必须知道的限制：

1. **下载失败会被吞掉。** `curl -f` 失败时管道仍然是「成功」的（`sh` 拿到空输入，什么都不执行，退出码 0）。定时任务看到的是「这轮正常结束」，而实际上什么都没做。如果只是偶尔抖动，下一轮会自愈；如果你需要「失败必须可见」，用上面两种写法。
2. **不要在管道里做兜底。** `curl A || curl B | sh` 这种写法有两个坑：
   - A 成功时，它的输出被**丢弃**，实际执行的是 `curl B | sh` —— 你以为是 A 的版本，其实跑的是 B；
   - 两个都失败时，`sh` 拿到空输入，静默成功退出 0。

   要兜底就把它们括起来：`( curl A || curl B ) | sh`，或者干脆落到临时文件（见上）。

> 想让管道写法也暴露失败，可以在你自己的外层包一层 `set -o pipefail`（busybox sh 也支持）：
> ```sh
> set -o pipefail
> curl -fsSL "$URL" | sh -s -- --compose myapp
> ```
> 这样 `curl` 失败时整条命令返回非 0。

## 2. 固定版本，别跟着 main 跑

README 里所有示例都用 `/v0.1.0/` 这样的 **tag 路径**，不是 `/main/`。

原因：这是会自动改生产容器的脚本。用 `/main/` 意味着上游任何一次提交第二天就会跑在你的机器上。用 tag 路径，升级变成一次显式的版本号替换。

升级时只改 URL 里的版本号即可：

```sh
URL=https://github.mus.pp.ua/https://raw.githubusercontent.com/geekMus/container-autoupdate/v0.1.1/container-autoupdate.sh
```

> 注意：**必须用短 tag 形式 `/v0.1.0/`**。某些加速服务（含自建的那套）对 `refs/tags/v0.1.0` 形式会超时。

## 3. 国内网络：换镜像源

`raw.githubusercontent.com` 在国内经常连不上（实测多次 8 秒超时）。可用的替代前缀：

| 前缀 | 形式 | 备注 |
|---|---|---|
| `https://github.mus.pp.ua/` | `https://github.mus.pp.ua/https://raw.githubusercontent.com/...` | 自建，最快 |
| `https://gh-proxy.com/` | `https://gh-proxy.com/https://raw.githubusercontent.com/...` | 公共 |
| `https://ghproxy.net/` | `https://ghproxy.net/https://raw.githubusercontent.com/...` | 公共 |
| `https://cdn.jsdelivr.net/` | `https://cdn.jsdelivr.net/gh/geekMus/container-autoupdate@v0.1.0/container-autoupdate.sh` | 路径格式不同，注意 `@` 版本号 |

## 4. 退出码

| 退出码 | 含义 | 该做什么 |
|---|---|---|
| `0` | 成功更新 / 无需更新 / 按规则安全跳过 | 不用管 |
| `1` | 配置或环境错误，或本轮更新没完成（**容器保持原样**） | 看日志里的 `ERR`；容器没被改动，不需要救 |
| `2` | **回滚本身失败了**，需要人工介入 | 立刻看日志里的 `CRITICAL`；现场保留在 `--state-dir`（默认 `/tmp/.container-autoupdate`） |

`2` 是唯一需要你动手的情况。脚本会保留现场（新容器、旧容器、tag 状态），不要急着重启机器或 `docker system prune`。

## 5. 定时器细节

### DPanel 计划任务

- 脚本框里可以直接写多行 shell，`curl | sh` 也可以。
- **执行超时设 ≥ 600 秒**。脚本自身硬上限是 540 秒（`T_HARD`），留出余量。
- DPanel 在 UI 里编辑任务时，**会把你手填的「执行超时」和「EntryShell」两个字段丢掉**（这是 DPanel 的已知行为）。改完排期后回来确认一下超时还在。
- 想给脚本传环境变量，用任务面板的 Environment 项（DPanel 原生支持，执行时会和 Docker 环境合并）。
- 多个任务可以并存，各自填不同的目标。**同一目标不要同时挂两个任务**（会互相抢锁，第二个会 `SKIP`，不危险但浪费一轮）。

### cron

```sh
0 4 * * * /usr/local/bin/container-autoupdate.sh --compose myapp >> /var/log/ct-update.log 2>&1
```

- cron 的 `PATH` 很窄，脚本会自己找 `docker`，但如果 docker 装在非常规位置，先确认 `which docker`。
- 要错开多个目标，直接写不同时间点即可；**同一目标不要写两条**。
- 日志建议追加到文件而不是丢给 `MAILTO`，出问题好回溯。

### systemd timer

```ini
# /etc/systemd/system/ct-update.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/container-autoupdate.sh --compose myapp
```

```ini
# /etc/systemd/system/ct-update.timer
[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

`Persistent=true` 的好处：机器关机错过了时间点，开机后会补跑一次。

## 6. 同一台机器管多个目标

脚本按**更新目标**加互斥锁（不是全局锁），所以不同目标可以并行：

```sh
container-autoupdate.sh --compose app1 &
container-autoupdate.sh --compose app2 &
wait
```

同一目标的两个进程会串行：后到的那个打印 `SKIP 同一更新目标…的另一个任务仍在执行` 并退出 0。

如果想让多份脚本副本完全独立（各自的状态目录和锁），给它们不同的 `--state-dir` 和 `LOCK_PREFIX`。

## 7. 常见问题

**Q：日志说「已是最新」，但明明上游发版了。**
A：脚本比对的是**远端 digest** 与**容器实际运行的镜像**。上游发了版但 tag 内容没变（很少见）、或者你用的是固定 digest 引用，都会这样。先用 `--dry-run` 看它认到的远端 digest 是什么。

**Q：日志说「SKIP 容器 xxx 属于 Compose 项目 yyy」。**
A：这个容器是 compose 起的，应该用 `--compose yyy`，让 compose 负责重建。用容器模式重建会让 compose 的元数据错位。

**Q：更新后容器起来了但服务不正常，脚本却说成功。**
A：脚本只能判断「容器健康」，判断不了「业务正确」。镜像自带 healthcheck 时门禁比较可靠；没有 healthcheck 时只观察 30 秒是否仍在运行（`PLAIN_BOOT`），这对启动后就崩、或半死不活的服务是盲区。这类服务建议在 Compose 里加 healthcheck。

**Q：回滚之后数据不对了。**
A：回滚只恢复**容器和镜像**，不会撤销新版本程序已经对数据卷/数据库做过的迁移。这是设计边界，不是 bug。生产数据请另做备份。

**Q：能不能一次更新多个目标？**
A：不能，一个进程一个目标。要批量就在外面套一层循环或并行（见第 6 节）。

**Q：`--state-dir` 里的文件能删吗？**
A：脚本退出时会自己清理，只有退出码 `2` 时会故意保留现场。平时不用管。
