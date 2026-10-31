# 进阶用法

> 基础用法看 [README](../README.md)。这里讲的是**下载方式、退出码、定时器细节，以及几个容易踩的坑**。

## 1. 怎么把脚本弄到机器上

三种方式，按可靠性从高到低。

### 推荐：先下载到文件，再执行

```sh
curl -fsSL https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh \
  -o /usr/local/bin/container-autoupdate.sh
chmod +x /usr/local/bin/container-autoupdate.sh
/usr/local/bin/container-autoupdate.sh --compose myapp
```

好处：下载失败会明确报错并返回非 0 退出码，定时任务能看出这轮没跑成。

### 次选：先落到临时文件，再执行（不污染磁盘）

```sh
URL=https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
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

## 2. 版本：默认跟最新发布版，也可以锁死

**默认用法**：`releases/latest/download/container-autoupdate.sh`

这个地址**不含版本号，永远指向最新发布的 Release**。好处是你粘贴一次就不用再管了，作者发新版你下一轮就自动用上。

它和 `/main/` 不一样：`/main/` 指向分支最新提交，包含还没发布的中间状态（包括改文档的提交）；`releases/latest/` 只指向**已经通过校验并正式发布**的版本。

**想锁死版本**：把 `latest/download` 换成具体 tag。

```sh
https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/download/v0.2.0/container-autoupdate.sh
```

什么时候该锁死：你不想在无人值守的生产环境上突然换行为。锁死之后，升级变成一次显式的版本号替换。

查看当前用的是哪个版本：

```sh
sh container-autoupdate.sh --version
```

> **发版机制**：仓库里的 `VERSION` 字段（脚本第 53 行附近，形如 `VERSION="0.2.0"`）是唯一版本来源。推到 `main` 时，GitHub Actions 会读它，若对应 tag 不存在就自动打 tag 并发布 Release，并把脚本作为 Release 资产上传。所以升级只需要改 `VERSION` 一个地方，README 和下载地址都不用动。

> 注意：**`refs/tags/v0.2.0` 这种形式不要用**。某些加速服务（含自建的那套）对它超时。用 `/releases/download/v0.2.0/` 或短 tag 路径。

### 用 latest 时，破坏性变更会怎么表现

这是「用 latest 也安全」的机制说明。上游改坏了你的调用方式时，脚本分三类处理：

| 变更类型 | 例子 | 脚本怎么办 |
|---|---|---|
| 参数被移除/改名 | `--target` 拆成 `--compose` / `--container` | **立刻中止**，退出码 `3`，日志写明「哪个参数不能用了、从哪个版本起改成什么、怎么改」 |
| 环境变量被移除/改名 | `UPD_TARGET` 拆成 `UPD_COMPOSE` / `UPD_CONTAINER` | 同上 |
| 默认行为/语义变化 | 回滚副本默认从 1 份变 2 份 | 无法从输入判断，用下面两个机制兜住 |

后一类靠这两个机制：

**① 跨版本提示。** 脚本会在 `--state-dir` 下记住每个目标上次跑过的版本（`compat/compose-<名>/lastver`、`compat/plain-<名>/lastver`）。当本次版本更高、且两者之间存在破坏性变更时，日志开头会多一段：

```sh
[2026-11-01 03:52:03] WARN 你从 1.0.0 之前的版本(0.2.0)升级上来，v1.0.0 引入了破坏性变更
[2026-11-01 03:52:03]      变更：默认保留 2 份回滚副本
[2026-11-01 03:52:03]      应对：如只想保留 1 份，加 --keep 1
[2026-11-01 03:52:03]      本次仍会继续执行。若你依赖旧行为，请加 --compat 0.2.0 或改用固定版本
```

它**不中止**（因为不确定你是否依赖旧行为），只提示。同一版本不会重复提示；降级也不会提示。

**② `--compat <版本>`。** 你可以声明「我只验证到某个版本」。如果脚本版本更高、且中间有破坏性变更，它会硬停（退出码 `3`）而不是冒险执行：

```sh
container-autoupdate.sh --compose myapp --compat 0.2.0
```

适合的场景：你在生产上验证过 `0.2.0`，但某天 `latest` 跳到 `1.0.0`，你还没时间做回归——加上 `--compat 0.2.0` 就等于「只要碰到我没验证过的破坏性变更就别动我的容器」。等你验证完了，把数字改成新版本或直接去掉。

`--compat` 的边界行为：

- 值不合法（如 `abc`）→ 退出码 `3`
- 值比脚本还新（例如脚本 `1.0.0` 但你写 `--compat 1.5.0`，通常是下载地址写错了）→ 退出码 `3`
- 值等于或高于变更版本 → 放行
- 没有任何登记在案的破坏性变更 → 直接放行，不打扰

> 维护者视角：破坏性变更登记在脚本里的 `BREAKING_TABLE`。新增能力、改日志措辞、改内部实现都**不要**登记，否则每次发版都在打扰用户。

## 3. 国内网络：换镜像源

`raw.githubusercontent.com` 在国内经常连不上（实测多次 8 秒超时）。可用的替代前缀：

| 前缀 | 形式 | 备注 |
|---|---|---|
| `https://github.mus.pp.ua/` | `https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh` | 自建，最快 |
| `https://gh-proxy.com/` | `https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh` | 公共 |
| `https://ghproxy.net/` | `https://ghproxy.net/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh` | 公共 |

也可以用**直连**（不加前缀）：`https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh`。实测在部分网络下直连 Release 资产比 raw 文件更稳（raw 会 8 秒超时，Release 资产直连成功）。

> **一定要带 `-L`**（或 `--location`）。`releases/latest/download/` 会先返回 302 跳到具体 tag 的地址，不带 `-L` 时 `curl -f` 会把它当失败（`curl: (22)`）。本文所有示例都带 `-L`。
>
> 加速源对 Release 资产**偶发** `403` / `522`（实测同一地址几分钟前 403、几分钟后 200）。这是加速源侧的抖动，不是地址写错——重试一次通常就好。这也正是「先落临时文件再执行」值得用的原因：失败会变成可见的非 0 退出码。
>
> `cdn.jsdelivr.net` **不要用于本仓库**：实测它返回的是缓存旧版本（`@main` 拿到过 `VERSION=6.0.0` 的历史内容）。jsdelivr 适合固定 tag 的静态文件，不适合「跟最新发布版」的场景。

## 4. 退出码

| 退出码 | 含义 | 该做什么 |
|---|---|---|
| `0` | 成功更新 / 无需更新 / 按规则安全跳过 | 不用管 |
| `1` | 配置或环境错误，或本轮更新没完成（**容器保持原样**） | 看日志里的 `ERR`；容器没被改动，不需要救 |
| `2` | **回滚本身失败了**，需要人工介入 | 立刻看日志里的 `CRITICAL`；现场保留在 `--state-dir`（默认 `/tmp/.container-autoupdate`） |
| `3` | **检测到破坏性变更**，你的调用方式已失效（本次未做任何改动） | 按日志里的「迁移方式」改命令；或锁版本；或加 `--compat` |

`2` 是唯一需要你动手抢救的情况。脚本会保留现场（新容器、旧容器、tag 状态），不要急着重启机器或 `docker system prune`。

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
