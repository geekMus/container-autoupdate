# 进阶用法

> 语言：[中文](advanced-usage.md) | [English](advanced-usage.en.md)

> 基础用法看 [README](../README.md)。这里讲的是**下载方式、退出码、计划任务细节，以及几个容易踩的坑**。
>
> 脚本是给 **DPanel 计划任务**用的：跑一轮就结束，频率与并发交给 DPanel。
> 同一目标只挂一个计划任务即可（脚本内部没有互斥锁）。手动跑是单次运行，
> 不建议再套 cron / systemd timer。

## 1. 怎么把脚本弄到机器上

**生产环境推荐用引导器**（`ct-bootstrap.sh`）：它负责下载与缓存，你只维护一行命令。

### 推荐：用引导器（自带缓存，不必每轮联网）

```sh
curl -fsSL https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh \
  -o /usr/local/bin/ct-bootstrap.sh
chmod +x /usr/local/bin/ct-bootstrap.sh
/usr/local/bin/ct-bootstrap.sh --compose myapp
```

引导器每次运行的行为：

| 情形 | 网络开销 |
|---|---|
| 设了 `--ct-version <版本号>`（或 `CT_VERSION`），本地已有 | **零**（完全不联网） |
| 默认（跟 latest），本地同版本 | 一次 4KB Range 探测（约 1 秒），不下载 |
| 默认，远端有新版本 | 探测 + 一次 64KB 下载，然后缓存 |
| 探测失败但本地有缓存 | 零（用缓存，打 `WARN`） |
| 探测失败且无缓存 | 零，但**明确报错退出**（不会静默成功） |

好处有三个：下载失败会明确返回非 0；缓存命中时不必联网（镜像源抖动不影响脚本启动）；缓存文件会做语法 + 版本号 + 特征字符串校验，半截文件不会被当脚本执行。

全部配置项见 [参数文档](parameters.md#引导器ct-bootstrapsh的参数与环境变量)。

### 备选：直接下载主脚本到文件，再执行（不缓存）

如果你不想用引导器，就直接跑主脚本。注意此时**脚本不会自己升级**，你得自己定期重下：

```sh
curl -fsSL https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh \
  -o /usr/local/bin/container-autoupdate.sh
chmod +x /usr/local/bin/container-autoupdate.sh
/usr/local/bin/container-autoupdate.sh --compose myapp
```

### 仅用于验证：落到临时文件再执行（不污染磁盘）

想快速验证网络与参数、又不留文件时用这个：

```sh
URL=https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
_t=$(mktemp)
if curl -fsSL --max-time 60 "$URL" -o "$_t"; then
  sh "$_t" --compose myapp
else
  echo "下载失败" >&2; rm -f "$_t"; exit 1
fi
rm -f "$_t"
```

下载失败时 `exit 1` 会出现在任务日志里，而不是静默当成成功。**但它每轮都要下载**，不建议用于生产。

### 不建议：直接管道执行

```sh
curl -fsSL "$URL" | sh -s -- --compose myapp
```

能跑，但有三个必须知道的限制：

1. **下载失败会被吞掉。** `curl -f` 失败时管道仍然是「成功」的（`sh` 拿到空输入，什么都不执行，退出码 0）。定时任务看到的是「这轮正常结束」，而实际上什么都没做。
2. **每轮都要联网下载**，镜像源抖动（403/522/`Recv failure`）就会让这一轮跑不起来。
3. **不要在管道里做兜底。** `curl A || curl B | sh` 这种写法有两个坑：
   - A 成功时，它的输出被**丢弃**，实际执行的是 `curl B | sh` —— 你以为是 A 的版本，其实跑的是 B；
   - 两个都失败时，`sh` 拿到空输入，静默成功退出 0。

   要兜底就把它们括起来：`( curl A || curl B ) | sh`，或者干脆落到临时文件（见上）。

> 想让管道写法也暴露失败，可以在你自己的外层包一层 `set -o pipefail`（busybox sh 也支持）：
> ```sh
> set -o pipefail
> curl -fsSL "$URL" | sh -s -- --compose myapp
> ```
> 这样 `curl` 失败时整条命令返回非 0。
>
> **但它有一个副作用**：如果脚本在读完输入之前就退出了（`--version`、`--help`、参数错误这类秒退场景），`curl` 会拿到 `curl: (23) Failure writing output to destination`，整条管道于是返回 `23`——即使脚本本身是成功的。实测：`--version` 带 pipefail 返回 `23`，`--compose ... --dry-run` 跑到末尾返回 `0`。
>
> 所以 **pipefail 只适合固定参数、会跑完整个流程的场景**（比如写死在 DPanel 计划任务里的 `--compose myapp`）。要用 `--version`/`--help` 或参数可能出错时，改用上面的临时文件写法。

## 2. 版本：默认跟最新发布版，也可以锁死

**默认用法**：引导器的地址用 `releases/latest/download/ct-bootstrap.sh`，它每次运行会自己判断要不要更新主脚本。

它和 `/main/` 不一样：`/main/` 指向分支最新提交，包含还没发布的中间状态（包括改文档的提交）；`releases/latest/` 只指向**已经通过校验并正式发布**的版本。

**想锁死版本**：给引导器加 `--ct-version`（不用改下载地址；也可用环境变量 `CT_VERSION`）：

```sh
/usr/local/bin/ct-bootstrap.sh --ct-version 1.2.3 --compose myapp
```

锁死后引导器**完全不联网取新版本**——本地有该版本就直接跑。这是生产环境最稳的形态。

如果你不用引导器、直接跑主脚本，那就把地址里的 `latest/download` 换成具体 tag（tag 号见 [Releases](https://github.com/geekMus/container-autoupdate/releases)）：

```sh
https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/download/v1.2.3/container-autoupdate.sh  # 示例占位：把 v1.2.3 换成 Releases 页面上的真实 tag
```

什么时候该锁死：你不想在无人值守的生产环境上突然换行为。锁死之后，升级变成一次显式的版本号替换。

查看当前用的是哪个版本：

```sh
sh container-autoupdate.sh --version
```

> **发版机制**：仓库里的 `VERSION` 字段（脚本顶部 `VERSION` 字段，形如 `VERSION="1.2.3"`）是唯一版本来源。推到 `main` 时，GitHub Actions 会读它，若对应 tag 不存在就自动打 tag 并发布 Release，并把脚本作为 Release 资产上传。所以升级只需要改 `VERSION` 一个地方，README 和下载地址都不用动。

> 注意：**`refs/tags/<tag>` 这种形式不要用**。某些加速服务（含自建的那套）对它超时。用 `/releases/download/<tag>/` 或短 tag 路径。

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
[2026-11-01 03:52:03] WARN 你从 1.0.0 之前的版本(0.9.0)升级上来，v1.0.0 引入了破坏性变更
[2026-11-01 03:52:03]      变更：默认保留 2 份回滚副本
[2026-11-01 03:52:03]      应对：如只想保留 1 份，加 --keep 1
[2026-11-01 03:52:03]      本次仍会继续执行。两条路选一条：
[2026-11-01 03:52:03]        1) 接受上面的新做法（想让下一次破坏性变更前先停住，可加 --compat 1.0.0）
[2026-11-01 03:52:03]        2) 想继续用旧行为，把下载地址固定到 v0.9.0 那个 tag
```

它**不中止**（因为不确定你是否依赖旧行为），只提示。同一版本不会重复提示；降级也不会提示。

> 注意别照着提示去加 `--compat 0.9.0`：那个值会让下面的 `--compat` 机制**硬停**（退出码 `3`），
> 等于每次跑都停。想要「先停住」应该写 `--compat 1.0.0`（= 当前脚本版本）。

**② `--compat <版本>`。** 你可以声明「我只验证到某个版本」。如果脚本版本更高、且中间有破坏性变更，它会硬停（退出码 `3`）而不是冒险执行：

```sh
container-autoupdate.sh --compose myapp --compat 0.9.0
```

适合的场景：你在生产上验证过 `0.9.0`，但某天 `latest` 跳到 `1.0.0`，你还没时间做回归——加上 `--compat 0.9.0` 就等于「只要碰到我没验证过的破坏性变更就别动我的容器」。等你验证完了，把数字改成新版本或直接去掉。

`--compat` 的边界行为：

- 值不合法（如 `abc`）→ 退出码 `3`
- 值比脚本还新（例如脚本 `1.0.0` 但你写 `--compat 1.5.0`，通常是下载地址写错了）→ 退出码 `3`
- 值等于或高于变更版本 → 放行
- 没有任何登记在案的破坏性变更 → 直接放行，不打扰

> 维护者视角：破坏性变更登记在脚本里的 `BREAKING_TABLE`。新增能力、改日志措辞、改内部实现都**不要**登记，否则每次发版都在打扰用户。

## 3. 国内网络：换镜像源

`raw.githubusercontent.com` 在国内经常连不上（实测多次 8 秒超时）。引导器的默认源已经处理了这件事（`CT_SOURCE=auto` 会依次试 gh-proxy → 直连 → ghproxy.net）。手写地址时的替代前缀：

| 前缀 | 形式 | 备注 |
|---|---|---|
| `https://gh-proxy.com/` | `https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh` | **实测最稳**：Range 4KB 与完整下载都约 1 秒 |
| `https://ghproxy.net/` | `https://ghproxy.net/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh` | 公共（实测多次 15 秒超时，引导器只作为最后兜底） |
| `https://github.mus.pp.ua/` | `https://github.mus.pp.ua/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh` | 自建（会偶发 403/522，实测不如 gh-proxy 稳） |

也可以用**直连**（不加前缀）：`https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-bootstrap.sh`。直连 Release 资产比 raw 文件稳，但实测会偶发 DNS 失败（`curl: (6)`）和 12 秒延迟，所以引导器把它排在 gh-proxy 之后。

> **一定要带 `-L`**（或 `--location`）。`releases/latest/download/` 会先返回 302 跳到具体 tag 的地址，不带 `-L` 时 `curl -f` 会把它当失败（`curl: (22)`）。
>
> 加速源对 Release 资产**偶发** `403` / `522`（实测同一地址几分钟前 403、几分钟后 200）。这是加速源侧的抖动，不是地址写错——重试一次通常就好。引导器对每个源默认试 2 次（`CT_TRIES`），并在探测失败时回退到本地缓存。
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

## 5. 计划任务细节

### DPanel 计划任务（推荐）

- 脚本框里可以直接写多行 shell，`curl | sh` 也可以。
- **执行超时设 ≥ 600 秒**。脚本自身硬上限是 540 秒（`T_HARD`），留出余量。
- DPanel 在 UI 里编辑任务时，**会把你手填的「执行超时」和「EntryShell」两个字段丢掉**（这是 DPanel 的已知行为）。改完排期后回来确认一下超时还在。
- 想给脚本传环境变量，用任务面板的 Environment 项（DPanel 原生支持，执行时会和 Docker 环境合并）。
- 多个任务可以并存，各自填不同的目标。**同一目标只挂一个计划任务**（脚本内部没有互斥锁，两个任务同时跑会互相踩）。

### 手动跑一轮

```sh
container-autoupdate.sh --compose myapp
```

跑完就结束，适合「现在查一下有没有新版」。

### 关于 cron / systemd timer

**不推荐**用 cron 或 systemd timer 定时跑这个脚本：脚本内部不再加互斥锁，同一目标同时跑两轮会互相踩。要定时更新就用 DPanel 计划任务。

（如果你确实要用 cron，请自行保证同一目标同一时刻只有一个实例在跑，例如在 crontab 表达式里错开时间点。）

## 6. 同一台机器管多个目标

不同目标互不影响，可以同时跑：

```sh
container-autoupdate.sh --compose app1 &
container-autoupdate.sh --compose app2 &
wait
```

**同一目标**不要同时跑两个（脚本不再加锁挡你），否则两轮会互相踩。等前一轮结束再跑下一轮。

如果想让多份脚本副本完全独立（各自的状态目录），给它们不同的 `--state-dir`。

## 7. 排查残留进程与旧锁文件

旧版本（用互斥锁的那些）有时会反复打出：

```sh
[2026-11-02 19:00:05] SKIP 同一更新目标（compose-myapp）的另一个任务仍在执行，本轮跳过
```

而且**每一轮一模一样、什么都没更新**。原因不是真的有别的任务在跑，而是**上一轮有个子进程没退干净**，
它替主脚本一直占着锁（详见 [工作方式与安全边界](how-it-works.md)）。

仓库里带了一个**只读**排查脚本 `scripts/ct-stale-lock-check.sh`：它不改任何东西、不杀任何进程，
只把下面这些列出来，最后给出可复制的清理命令：

1. 旧的锁文件（当前版本已不使用锁，它们只是残留垃圾）；
2. 谁正开着这些锁文件（PID / PPID / fd / 命令行）；
3. 残留的镜像拉取进程；
4. 状态目录里残留的事务目录，并标注哪些能删、哪些要留。

### 怎么用

```sh
curl -fsSL -L https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh \
  -o /tmp/ct-stale-lock-check.sh
sh /tmp/ct-stale-lock-check.sh
```

**要在跑更新的那个环境里跑**：脚本看的是那台机器的 `/proc`。用 DPanel 的话就是容器内部：

```sh
docker cp /tmp/ct-stale-lock-check.sh dpanel:/tmp/ct-stale-lock-check.sh
docker exec -it dpanel sh /tmp/ct-stale-lock-check.sh
```

可选环境变量：`CT_LOCK_PREFIX`（锁文件前缀，默认 `/tmp/.container-autoupdate`）、
`CT_STATE_ROOT`（状态目录，默认 `/tmp/.container-autoupdate`）。

### 看到结果之后

| 看到的东西 | 能不能删 | 说明 |
|---|---|---|
| 旧的 `.lock` 文件 | **可以删** | 当前版本不再使用锁，留着只是垃圾。删掉不影响任何功能。 |
| 占着锁的进程 | **先确认再杀** | 先看它的命令行：`cat /proc/<PID>/cmdline`（NUL 分隔）。确认是没退干净的残留再 `kill <PID>`。 |
| 残留的拉取进程（`images/create`） | **可以杀** | 拉取早就该结束了，活着的那个是残留，杀掉即可。 |
| `compat/` 目录 | **可以不删** | 只是「每个目标上次跑过的版本」的记录，删掉只会在下次升级时多提示一次。 |
| 事务目录（`compose-*` / `plain-*`） | **先看日志再删** | 说明那一轮出过问题。里面的 `pull.log` / `create.json` 是「为什么失败」的唯一证据。 |

### 真正的解法

清垃圾只是治标。**根治是升级到不再使用互斥锁的版本**——新版本没有锁，也就不存在「被残留进程占住」这回事。
升级后确认两件事：同一个目标只挂一个 DPanel 计划任务；启动命令里没有残留的 `LOCK_PREFIX=...`
（有的话脚本会按破坏性变更中止，退出码 `3`）。

## 8. 常见问题

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
A：分三种情况：

- **正常成功收尾**（退出码 `0`）：事务目录会自动清掉，不用管。
- **回滚成功**（退出码 `1`，容器已复原）：现场会**故意保留**，因为 `create.json` / 新旧规格 / `pull.log` 是「这一轮为什么失败」的唯一证据，日志末尾会打「回滚现场已保留在 …」。排查完手动删掉即可。
- **回滚本身失败**（退出码 `2`）：现场必须保留，人工接手时全靠它。

动手前那份 `--state-dir` 目录本身不会被清空，只是每轮的事务子目录。
