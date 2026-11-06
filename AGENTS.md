# AGENTS.md —— 修改本仓库的硬性规则

面向在本仓库动手的 **AI 代理与人类维护者**。

这些规则不是风格偏好，每一条都对应一次真实的失败：某个命令炸了、某个「已验证」其实是假的、某个回滚点被悄悄删掉、某个 Release 资产和 HEAD 不一致。**与个人习惯冲突时，以本文件为准。**

---

## 0. 动手前先读

| 读什么 | 为什么 |
|---|---|
| `container-autoupdate.sh` 头部注释 | 安全原则的原始表述 |
| `container-autoupdate.sh` 的 `VERSION` | 改脚本必须升版本（§7） |
| `container-autoupdate.sh` 主流程（文件末尾） | 退出码与收尾逻辑在哪决定 |
| `docs/how-it-works.md` | 安全不变量：什么情况该跳过 |
| `docs/releasing.md` | 发版链路 |
| 本文件 | 下面全部 |

---

## 1. 三条铁律

1. **改生产之前先备份，并当场写下回退命令。** 没有回退命令的改动不许做。
2. **任何「更新」类操作，先用 `--dry-run` 确认脚本认到的目标与目录是对的**，再去掉它。
3. **说「已验证」之前，必须能贴出可复现的命令与真实输出。** 不允许「应该没问题」「大概是」「理论上」。无法验证的，就明说无法验证。

---

## 2. 环境与工具链（Windows → Linux 远端）

本仓库的维护环境是 Windows + PowerShell，目标机是 Linux（本项目实际是 N1 `192.168.31.200` 上的 `dpanel` 容器，busybox `sh`/`ash`）。这四类坑全部真实发生过。

### 2.1 不许把复杂命令拼进一行 `ssh`

PowerShell 向 `ssh` 传参会**剥掉内层引号**，导致远端语法错误：

```
ssh ... "docker exec dpanel sh -c '...'"      # 必炸
→ sh: syntax error: unexpected "("
→ 为 outputFormat 参数指定了无效的值(StrictHostKeyChecking=no)
→ 无法加载模块"退出码"
```

**正确做法**：多步远端操作一律落地成 `.sh` 文件 → `scp` → `docker cp` → `docker exec sh 文件`。

```powershell
scp -o StrictHostKeyChecking=no .\x.sh root@192.168.31.200:/tmp/x.sh
ssh -o StrictHostKeyChecking=no root@192.168.31.200 "docker cp /tmp/x.sh dpanel:/tmp/x.sh; docker exec dpanel sh /tmp/x.sh"
```

### 2.2 不许用 base64 把长脚本塞进单行 ssh

会直接断连：`Connection to 192.168.31.200 closed by remote host. [exit code: 1]`。一律 `scp` 落地。

### 2.3 行尾必须是 LF，且必须验证

- `[IO.File]::WriteAllLines` 会写出 **CRLF**，被 `sh` 解析成 `do\r` → `syntax error: unexpected word (expecting "do")`。
- 生成 shell 脚本必须 `WriteAllText` + `-replace "`r`n","`n"`，写完**核对 CR 计数为 0**。
- 仓库已有 `.gitattributes`（`* text=auto eol=lf`、`*.sh text eol=lf`），但 Windows 上 `core.autocrlf=true`，首次提交仍可能把 CRLF 存进 git。提交后要核对。

### 2.4 不许用 PowerShell 管道判断 git 里的行尾 / 内容

PowerShell 管道会**重新编码**输出，产生假警报（曾据此误判「仓库里存的是 CRLF」）。核对原始字节必须走 Python：

```powershell
& $py -c "import subprocess;print(repr(subprocess.run(['git','show','HEAD:container-autoupdate.sh'],capture_output=True).stdout[:80]))"
```

### 2.5 不许用 `git push` 的退出码判断成败

`git push` 成功时 stderr 也会输出 `To https://...`，在 PowerShell 里表现为 NativeCommandError + `[exit code: 1]`，**实际是成功的**。核对方式：

```powershell
git fetch origin; git rev-parse HEAD; git rev-parse origin/main    # 两个 sha 相同才算推送成功
```

### 2.6 大段 here-string 含密码占位符会被安全网拦截

`Error: BLOCKED by CC Safety Net`（`analysis.strict-unparseable` / `analysis.dynamic-shell-source`）。改用 write 工具落地脚本文件，再 `scp`。

---

## 3. 脚本不可退让的安全不变量

以下行为是经过 40+ 项故障实测才定下来的。**改脚本时不许为了「简洁」删掉其中任何一条。**

v2.1.0 起，脚本分两条路：**容器模式**把「拉镜像、重建容器、判健康、留回滚点」交给 DPanel 的命令行（`container:upgrade`）；**Compose 模式**用 docker 自己的 `docker compose pull` + `docker compose up -d` 就地重新部署。所以本节分成两半：**上面是当前必须守住的**，**下面标着「历史」的是 v1.x 时代自己拉取/重建、以及 v2.0.0 短暂把 Compose 交给 `compose:deploy` 时期的教训**——那些代码已经删掉，但你要是重写同类逻辑，不许重犯。

### MUST（v2.1.0 现行；镜像回收见 v5.0.0 补的那条）

- **容器模式的更新动作只许交给 DPanel**（`container:upgrade`），**不许在脚本里重新实现**「拉镜像 / 重建容器 / 复刻网络与挂载 / 健康门禁 / `:prev` 回滚点」——v1.x 为此写了一千多行，实测反复出事（拉取被误判卡死、失败原因打两遍、回滚点被清理逻辑误删）。要重建容器，先用**一次实验**证明你会比 DPanel 做得更对。
- **Compose 模式只用 compose 自己的命令**：`docker compose pull` 然后 `docker compose up -d`。**不许加 `--remove-orphans`**；不许手工 `tag` / `create` / `rm`；compose 参数（`COMPOSE_PROJECT_NAME` / `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` / `COMPOSE_ENV_FILES`）必须走环境变量（拼成命令行时，路径含空格会让 compose 打印 Usage 却返回 `rc=0`）。
- **（v5.0.0）Compose 部署成功后回收旧镜像，三条约束缺一不可**：① 归属本项目——**只认 `.RepoDigests`**（N-2 变 `<none>` 后 `Repository` 字段是 `<none>`，标签前缀永远匹配不到），本地 build/import 出来的没有 RepoDigests，认不出就留着；② 一个 tag 都没有（`RepoTags` 实测为空，不能只信 `dangling=true` filter）；③ 没有任何容器引用（`docker ps -a -q --filter ancestor=<id>` 为空——它同时覆盖已停止容器与 DPanel 的 `<容器名>-bak-<时间戳>` 备份容器）。**不许用 `docker image prune` / `docker rmi -f`**：prune 会连带删掉别的项目的 dangling，`-f` 会绕过 daemon 的引用保护。回收只在项目健康（`up -d` 成功、容器都在跑）且剩余预算 ≥ 20 秒时做；失败路径不回收。
  - **v5.0.0 起不再保留回滚点**（用户明确要求：`已重新部署` 之后就整批回收）。v4.1.0 曾把「更新前在用的那个」留着当回滚点，代价是稳态下每个 Compose 项目永远躺着一个 `<none>`。**不要再把这个「保留一个」的逻辑加回来**：那与「别堆积」自相矛盾。代价是 Compose 模式失去 `docker tag <旧镜像ID>` 回退路径，回退改为「把 compose 文件里的 `image:` 钉回旧 tag/digest 再跑一轮」——文档必须这么说，不许再说「旧镜像被刻意保留」。
- **Compose 的拉取失败了就不许部署**：`pull` 非 0 就报错退出（退出码 1），项目必须原样不动；`up -d` 失败同样报错退出码 1，脚本不许改 compose 文件或容器定义，要能让用户「直接再跑一轮」。
- **报告必须如实区分三种情况**：容器换了镜像（`已重建：<名>（旧12位 → 新12位）`）、这一轮新建的容器（`新建：<名>`）、真的什么都没变（`已是最新（拉取后没有容器需要重建）`）。把「新建」写成「已是最新」、或把「部署成功」写成「已更新到最新版」，都是不许的。
- **Compose 项目目录优先从容器标签反查**（`com.docker.compose.project.working_dir` / `.config_files` / `.environment_file`），反查不到才用 `--compose-dir` / `COMPOSE_DIR` 兜底；两者都没有就退出码 1 并给出二选一指引。不许靠「猜常见目录」。
- **DPanel 的成败只能解析 JSON 判**（容器模式）：`compose:deploy` 对未登记的项目返回 `rc=0`，JSON 却是 `{"code":500,...}`；成功时（`{"name":"<项目名>"}`）**根本没有 `code` 字段**。判定条件必须是「`code` ≥ 400 或 `status=failed` 或 `error` 非空才算失败」。
- **容器模式必须先检查、后升级**：先不带 `--upgrade` 调一次 `container:upgrade` 看 `upgrade` 是不是 `true`，是才真升级。跳过检查直接升级 = 每轮都重建容器。
- **不许传 `--disable-bak`**：DPanel 的备份容器（`<容器名>-bak-<时间戳>`）就是容器模式的回滚点，关掉它等于没有回滚点。
- **不许给 DPanel CLI 加 `-q` / `--quiet`**：它会把结果 JSON 一起吞掉（只剩 `[DEBUG]` 行），解析必然失败；`-q` 抑制的是命令结果，不是日志。
- **取 DPanel 结果的规则是「stdout 里最后一个以 `{` 开头的行」**：stdout 混着大量 `[DEBUG]` / GORM 日志，结果 JSON 永远在最后一行。
- **失败原因要透传，而且不能被截断**：把 DPanel 的 `error` 文本打进日志；取 JSON 字符串字段时**不能按逗号截断**（DPanel 的错误文本里就有逗号，实测会被切成半句，真实原因就丢了）。
- **参数写错就报错退出（`rc=1`）**：不认识的参数不许静默忽略，也不许自动改写；错误信息里点名是哪一项，并指向 `--help`。**环境变量没有这层检查**：不认识的环境变量会被直接忽略、不报错（v4.0.0 实测踩过：`CT_VERSION=1.2.3` 被忽略后脚本照常把生产项目更新了）——旧 env 只会「不生效」，不会「被拦」，测试这类行为必须指向不存在的目标（§6.5）。
- **失败原因必须同时落到真正的 stderr**（v1.1.2 起的设计，v2.0.0 保留）：计划任务（DPanel）在任务失败时**只保留 stderr、丢弃 stdout**；理由与实现要点见下面「历史 MUST」。

### NEVER（v2.1.0 现行）

- 不许用 DPanel CLI 的**退出码**判成败。实测三种失败（容器不存在、项目未登记、镜像清单读不到）退出码都是 `0`。
- 不许把「JSON 里没有 `code` 字段」当成失败——成功的形状就没有它。
- 不许自己写「有没有新版本」的 digest 比对：容器模式用 DPanel 返回的 `upgrade`；Compose 模式靠 `docker compose pull` 本身（**拉取就是判断**），别假装提前知道。
- 不许在 Compose 模式里手工 `docker tag` / `docker create` / `docker rm` 去动容器——只许 `docker compose pull` + `docker compose up -d`。
- 不许把「部署成功」写成「已更新到最新版」：`up -d` 成功只说明 compose 跑完了；版本变没变要看容器镜像 id 的比对结论（`已重建` / `新建` / `已是最新`）。
- 不许把「部署前没有这个容器」（`新建`）混进「已是最新」报出去——那是两种完全不同的事实。

### 历史 MUST（v1.x：脚本自己拉取与重建容器）

- **Compose 参数必须通过环境变量传**（`COMPOSE_PROJECT_NAME` / `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` / `COMPOSE_ENV_FILES`），保留原有的项目名、config 文件、env 文件。不许拼成命令行字符串（见下方 NEVER 第 3 条）。
- **不使用 `--remove-orphans`**：它会删掉不在当前 compose 文件里的容器，属于数据事故。
- **`:prev` 只能在健康门禁通过之后才移动。** 更新期间用 `<repo>:rollback-pending` 占位。
- **回滚必须用 `$OLD_IMGID`**，不许依赖 `:prev`（`:prev` 可能已被上一轮移动）。
- **中止路径必须把 tag 还原成更新前的镜像**（`abort_tags`）。否则 `:latest` 指向新镜像而容器还跑旧镜像，状态错位——此后任何一次手工 / DPanel 触发的重建都会把容器拉到**没经过健康门禁**的版本上。
- **拉取只 kill 本轮自己的 PID**，不许 `pkill` 按名字通杀（会杀掉别的并发任务）。
- **后台起子进程时 `$!` 只是那个子 shell 的 PID**，它 fork 出来的真正的进程（curl 等）`kill -9` 不到。要用 `--max-time` 之类给真实进程兜底，别指望 kill 能连坐。（v0.4.0 的真实故障：拉取用的 curl 活过了脚本，替主脚本一直占着锁。）
- **脚本内部不加互斥锁**：并发由 DPanel 计划任务保证，同一目标只挂一个计划任务。旧版的锁用 `exec 9>lock; flock -n 9` 持有，fd 9 会被子进程继承，残留的子进程能把锁长期占住，导致之后每一轮都 `SKIP` 并退出 0（生产上真实发生过：连续三轮日志完全一样）。已移除。
- **拉取失败的重试必须先分类，再决定要不要重试**：只有**瞬时**失败（网络抖动、429、5xx、拉取流中途断开）才重试；**永久**失败（镜像/仓库不存在、鉴权失败）与**卡死**（`T_STALL` 内没有新字节）不重试——重试一万次也一样，只是把时间预算耗光。分类依据是**拉取流自己报告的 `error` 字段**，不是 curl 的退出码：镜像源明确说「manifest unknown」时 curl 往往同时以非 0 退出，先看退出码就会把永久失败误判成瞬时故障。
- **失败原因必须同时落到真正的 stderr**：计划任务（DPanel）在任务失败时**只保留 stderr、丢弃 stdout**。失败原因只写在 stdout 上，计划任务里就只剩一句 `exit status 1`，排查时什么都看不到（生产上真实发生过：连续两轮失败，日志里只有引导器的两行，完全看不出主脚本为什么失败）。
  - 脚本里 `exec 2>&1` 会把 fd 2 指到 stdout，所以**必须在它之前**把真 stderr 另存一份（`exec 3>&2`），失败原因写那份。
  - `ERR` / `CRITICAL` 行**以及紧随其后的缩进补充行**（`log "   ..."`）都属于失败原因，要一起进 stderr —— 只写半截等于没写。
  - 用「上一个错误块是否还在延续」的标记来判断补充行的归属，不许靠猜缩进。
  - `WARN` 行**本身不是**失败原因，要看这一轮是不是已经判了失败（`EXIT_CODE=1`）：判了（例如「剩余时间不足，本轮不动手」）就必须跟 `ERR` 一样进 stderr；没判（例如 `docker compose config` 读不出镜像清单、流程照走）留在 stdout。所以**「先 `log "WARN ..."` 再 `EXIT_CODE=1`」这种顺序会漏掉它**——`EXIT_CODE=1` 必须写在 `log` 之前（v4.0.3 修的就是这个：两处预算不足的失败在计划任务里只剩 `exit status 1`）。
  - stdout 也要保留完整日志（两处都写），否则手动运行时日志会缺行。
- **查远端 digest 必须允许重试**：digest 查询是瞬时故障高发点，取不到就整轮放弃太脆。默认重试 2 次、间隔 5 秒（`DIGEST_RETRIES` / `DIGEST_RETRY_WAIT`）。
  - 重试结果用**全局变量**回传（`DIGEST_RESULT`），不许 `echo` 返回 —— 该函数在 `$( )` 里被调用，而 `log()` 写 stdout，`echo` 会把重试提示一起收进 digest 里。
  - 取不到时日志里要写明「已尝试 N 次」，别只写「取不到」。
- **拉取的「收尾阶段」必须给专门宽限**：Docker 把所有层拉完之后还要写镜像配置（回源查签名），那段时间拉取流**一个字节都不吐**。按「`T_STALL` 秒无字节 = 卡死」去判，会把一次快要成功的拉取掐掉；daemon 侧随即报 `context canceled`，**已经下载好的层全部作废**，整轮白跑（生产上真实发生过：层都 `Pull complete` 了，只差镜像配置）。
  - 层拉完之后（拉取流里 `Pull complete` 的数量追平 `Pulling fs layer` 的数量）必须进入**单独的收尾宽限**（`T_STALL_FINISH`，默认 180 秒），此期间不按 `T_STALL` 判卡死。
  - 收尾宽限用尽仍没拿到 digest 时，**先问 daemon 镜像是不是其实已经落盘了**，再决定是否 kill：真落盘了（tag 已指向新镜像、且 `RepoDigests` 有值）就按成功收场，不许白跑。
  - 判断「落盘」必须把**拉取前的本地镜像 id** 传进去做对比：tag 还指着旧镜像 ⇒ 没落盘；拿不到 id 就当作没落盘（宁可保守）。
- **失败原因只打印一次**：失败原因由 `pull_with_retry()` 统一打印（`ERR` 行 + 说明行），调用点只负责流程控制，**不许再打一遍同一条原因**。同一句话出现两遍会让人以为是两个不同的错误（生产上真实出现过：日志里「拉取失败 … 进度停滞」连着两行）。
- **坏版本 TTL 按「钉住时间」计算**（`date -d` 转 epoch），不许用镜像 `Created` 时间当锚点。
- **容器分支按容器 ID 操作**（不是名字），失败可恢复。
- **容器分支不把运行态 `NetworkSettings` 整包回投**；按声明式字段重建网络。
- **实际挂载（含匿名卷真实名称）转成显式 `Mounts`**，避免重复挂载和换卷。
- **创建后、启动前先做完整规格校验**（签名比对），不一致就别启动。

### 历史 NEVER（v1.x）

- 不许在 `docker compose pull` 之前就 `docker tag $CT_IMGID $PREV`（旧脚本这么干过：pull 失败时回滚点被搬走，原 N-1 失去最后一个 tag，下一轮清理把它当孤儿删掉，**回滚点消失**）。
- 不许用「脚本开始时的远端 digest 快照」做拉取后的校验（见 §4.3）。
- 不许在回滚失败时报成功。回滚失败必须 `exit 2`，并把现场留在 `--state-dir`。
- 不许用 `docker rmi <tag>` 当成「删镜像」——它只摘标签。
- 不许用 `--filter reference=` 找真 dangling 镜像——命中不了。
- 不许按「只有一个标签、且无容器引用 = 孤儿」清理镜像。`<repo>:prev`、`<repo>:bad`、`<repo>:rollback-pending` 通常正好符合这个特征，但它们**必须保留**。清理逻辑必须显式排除这三个保留标签——否则会静默删掉回滚点（真实踩过：生产 magpie 的 `:prev` 就这么没了）。
- 不许只用「`docker images` 的 `repo:tag` 前缀」来判断镜像属于哪个仓库。每次更新把 `:prev` 往前搬一格后，更早那版就失去最后一个标签、变成 `<none>:<none>`，它的 `Repository` 字段是 `<none>` 而**不是**本仓库名，前缀匹配永远看不到它 → **每成功更新一次就白留一个完整镜像**（实测：一次更新后留下 171MB dangling，日志里连「清理孤儿镜像」都没有）。必须先用 `.RepoDigests`（形如 `repo@sha256:...`，标签掉了也仍在）认领归属，标签前缀只能当兜底。
- 不许把 compose 参数拼成一个字符串再 `docker compose $args ...`。路径含空格时 compose **会打印 Usage 帮助却返回 rc=0**（静默出错，实测）。一律用 `COMPOSE_PROJECT_NAME` / `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` / `COMPOSE_ENV_FILES` 环境变量传递（见 §3 MUST）。
- 不许在 `check_deps` 里漏掉 `docker buildx`。`remote_digest()` 靠它读 manifest；缺它时 digest 恒为空，脚本每轮都报「无法获取远端 digest」而不更新——那个错误信息会把排查引向网络，与真实原因无关。
- 不许依赖 `sort -V`（GNU 扩展）。busybox/Alpine 没有它，换 runner 或换宿主会静默取错版本。版本比较用 awk 拆三段数字。

### 历史：v1.x 必须跳过的形态（并说明原因，不许硬上）

| 形态 | 原因 |
|---|---|
| 镜像引用是 digest（`...@sha256:...`） | 无法判断有没有新版 |
| `NetworkMode=container:*` | 共享别的容器网络，重建断链 |
| `VolumesFrom` | 卷归属在另一个容器上 |
| 非常规挂载 / 网络 | 无法可靠复现 |
| 由 Compose 管理的容器（走了 `--container`） | 会被 compose 认领冲突 |
| `AutoRemove` | 回滚副本会被 stop 删除 |
| 镜像声明了匿名卷且未显式允许 | 重建会换新卷、旧数据不跟随 |

---

## 4. （历史）v1.x 的拉取与进度判定

> v2.0.0 起**容器模式**不再自己拉镜像（交给 DPanel）；v2.1.0 起 **Compose 模式**用 `docker compose pull`，拉取完全交给 compose，本节讲的「自己读拉取流、按字节数判卡死、从流里抓 digest」那一套整节都是历史。留着是因为「怎么判断一次拉取到底成没成」这个问题不会消失，而下面每条都是实测踩出来的。

### 4.1 不许用 `docker pull` / `docker compose pull` 的 stdout 判断卡死

非 TTY 输出太粗：一次健康拉取只打印 39 行（`Pulling fs layer` / `Already exists` / `Pull complete` / `Download complete`），**没有进度条、没有字节数**，健康拉取也会出现 10~20 秒零增长。用它做「60 秒无增长就 kill」会**误杀正常更新**。

### 4.2 进度信号只能来自 Docker Engine API 流

```
POST /v1.47/images/create?fromImage=<urlencoded>&tag=<tag>
curl --unix-socket /var/run/docker.sock -sN -X POST ...
```

返回的 JSON 流含 `progressDetail`（一次拉取 65 处）+ 字节级 `"current":`，1~2 秒刷新。实测真实拉取的最长静默窗口仅 4 秒 → 60 秒阈值有 15 倍余量，不会误杀。

**路径必须带版本前缀 `/v1.47/`**。不带前缀返回 `{"message":"page not found"}`。

### 4.3 拉取后的 digest 校验必须用「拉取流自己报告的那一行」

```
{"status":"Digest: sha256:..."}
```

这是「本次真正落盘了哪一版」的权威记录。**不许重新问一次远端再比对**：上游发布很勤（实测 10 分钟内出现过 5 个不同 digest），只要拉取的几十秒里上游又发一版，拿开头快照比对就会把一次完全正确的拉取判成「不一致」而白白放弃（已实测命中）。

### 4.4 停滞判定要能自证

kill 时必须打印「共收 N 字节后无新增、停滞 M 秒」，否则事后无法判断是真卡死还是被误杀。

---

## 5. 时间预算

- 全脚本硬上限 `T_HARD=540` 秒；DPanel 任务的 `scriptRunTimeout` 设 **600**。
- **内部超时必须显著小于外部超时。** 被 DPanel SIGKILL 的那一轮，`ims_cron_log.value` 里的 message 是**空字符串**——进程被 KILL 前来不及 flush，日志里只剩一行 `signal: killed`，什么都查不到。
- v2.1.0 的预算分给五种调用：`DP_T_CHECK`（容器模式查有没有新版本，默认 120 秒）、`DP_T_UPGRADE`（容器模式真正升级，默认 420 秒）、`DP_T_PULL`（Compose 模式 `docker compose pull`，默认 420 秒）、`DP_T_UP`（Compose 模式 `docker compose up -d`，默认 180 秒）、`DP_MIN_UPGRADE`（低于这个剩余秒数就**不动手**，默认 90 秒）。
  - **每一次调用都要按剩余预算重新收敛**（不许直接用配置值），否则最后一句话没说完就被 SIGKILL。
  - 剩余时间不够时**提前收手并如实报错**，不许「试一把再说」——被 KILL 的那一轮在计划任务里什么都查不到。
  - Compose 模式的 `pull` 比容器模式慢（要逐层拉），但它失败时项目没被动过，属于「白跑一轮」而不是「留下半新半旧」；`up -d` 才是会改状态的那一步，所以它的超时可以短一些。

---

## 6. 测试规则

### 6.1 必须覆盖的场景矩阵

| 场景 | 期望 |
|---|---|
| 容器模式：已是最新 | 只调一次 `container:upgrade`（**不带** `--upgrade`），`rc=0`，零改动 |
| 容器模式：`--dry-run` | 同样只检查，报「发现新版本」但**不升级**，零改动 |
| 容器模式：真升级 | 调两次（检查 + `--upgrade`），生成 `<容器名>-bak-<时间戳>` 备份容器，主容器 running、镜像焕新 |
| 容器模式：DPanel 报失败（`status=failed`） | `rc=1`，日志里有 DPanel 的**原始错误文本** |
| 容器模式：剩余预算 < `DP_MIN_UPGRADE` | `rc=1`，**不动手** |
| 容器不存在 | `rc=1`，透传 `No such container`（不是「升级成功」） |
| Compose 模式：拉取后有变化 | `docker compose pull` → `docker compose up -d` → 报 `已重建：<名>（旧12位 → 新12位）` + `已重新部署（N/M 个容器换了镜像）`，`rc=0`，容器 id 变了 |
| Compose 模式：拉取后无变化 | 报 `已是最新（拉取后没有容器需要重建）`，`rc=0`，容器 id 不变（不许谎报 `已重建`） |
| Compose 模式：首次部署（部署前没有这个容器） | 报 `新建：<名>` + `已部署（N 个容器新建）`，**不许**说「已是最新」 |
| Compose 模式：`pull` 失败 | `rc=1`，**不执行** `up -d`，项目原样不动 |
| Compose 模式：`up -d` 失败 | `rc=1`，脚本不改 compose 文件、不手工动容器 |
| Compose 模式：`up` 之后有容器没在运行 | `rc=1`，日志逐条点名「名字 状态」 |
| Compose 模式：反查不到项目目录 | `rc=1`，给出二选一指引（`--compose-dir` / 确认项目名），错误进 stderr |
| Compose 模式：剩余预算 < `DP_MIN_UPGRADE` | `rc=1`，既不 pull 也不 up |
| Compose 模式：`--dry-run` | 只列出项目涉及的镜像，`rc=0`，不 pull 不 up，零改动 |
| 配置二选一（都填 / 都不填 / 名字不存在） | `rc=1`，不动任何东西 |
| 不认识参数 / 旧 flag | `rc=1`，点名是哪一项（旧 env 会被忽略、不报错，见 §6.5） |

### 6.2 制造「有新版本」的正确方法

容器模式的判据是 **DPanel 说要不要升级**（比较容器镜像与远端），所以要让**容器跑一个 DPanel 认不出 digest 的旧镜像**：

```sh
docker create --name _seed busybox:1.36        # 拿一份真镜像当种子
docker export _seed | docker import - ct_fake  # 导出再导入 ⇒ RepoDigests 为空
docker tag ct_fake busybox:1.36                # 顶掉 tag，DPanel 就会认为该升
```

测完必须把被顶掉的 tag 复原（重新 `docker pull` 并比对 digest），否则你留下的「假旧镜像」会污染后续每一轮判断。

**Compose 模式不能用上面这一招**：它的判据是 `docker compose pull` 拉到了什么，而 `export`/`import` 出来的镜像**丢了镜像配置**（实测：容器起不来，先是 `exec: "sleep": executable file not found in $PATH`，显式写 entrypoint 又报 `exec: "/bin/busybox": stat /bin/busybox: no such file or directory` —— 未启动的容器 `docker export` 出来是空的 rootfs）。正确做法是**拿一个真实可运行的旧标签顶替**：

```sh
docker pull busybox:1.35            # 真旧版本，能正常运行
docker tag busybox:1.35 busybox:1.36  # 顶掉 compose 文件里写的那个 tag
docker compose up -d                  # 让容器跑在 1.35 的内容上
# 现在跑脚本：pull 会把真 1.36 拉回来 → up -d 重建 → 应当报「已重建」
```

测完同样要把 tag 复原（重新 `docker pull busybox:1.36` 并比对 digest）。第一次部署（容器都还不存在）用 `STUB_NEWPROJ` 那类桩在本地测就行，别在生产机上删容器。

### 6.3 打桩方式

- 用 `awk` 改行，**不要用 `sed`**：`sed` 替换里带 `(`/`|` 等字符会报 `bad option in substitution expression`。
- 桩要改「行为」而不是「文案」，桩完必须验证 `sh -n`。

### 6.4 测试脚本自己的断言也会过期

曾把「脚本正确」误判成失败：断言里用的期望值在脚本启动时就采集了，而脚本钉 `:bad` 用的是**回滚那一刻**刚拉到的版本。看到失败先怀疑断言，再怀疑脚本。

### 6.5 测完必须复原

- 删掉所有测试容器：包括 `__old_*` 副本、以及 **DPanel 在升级时生成的 `<容器名>-bak-<时间戳>` 备份容器**（它是回滚点，但测试留下的那份必须清掉，不许让它堆在生产上）。
- 删掉测试镜像标签、测试状态目录；被测试顶掉的 tag 要重新 `docker pull` 复原并比对 digest。
- 复原被测试动过的生产状态：容器镜像与 tag 一致、无残留 `rollback-pending`。
- 确认生产容器仍 `healthy`。
- 删掉上传到生产机的测试脚本（容器内 `/tmp/...`、宿主 `/tmp/...`）——调试文件不许留。
- **在生产机上测「不认识的写法会被忽略」这类用例时，必须指向一个不存在的目标**（`--compose ct_no_such_project` / `--container ct_no_such`）：v4.0.0 没有兼容层，`CT_VERSION=1.2.3 sh … --compose magpie_gateway` 不会再被拦，它会**真的去更新生产项目**（v4.0.0 实测踩到：一次测试把生产 magpie_gateway 更新到了新镜像）。

---

## 7. 版本

### 7.1 `VERSION` 是唯一版本来源

- 不许在别处（脚本头部注释、usage 文本、文档示例）**硬编码当前版本号**——会过时。例外：文档里「锁死版本」的示例。
- `VERSION` 只能含数字和点，不带 `v` 前缀（工作流会拦）。

### 7.2 版本号怎么升

| 改动性质 | 版本段 |
|---|---|
| 修 bug、改文案、补日志 | patch |
| 加参数 / 加能力，向后兼容 | minor |
| 改默认行为、用户需改配置 | major 段 |

### 7.3 没有兼容层（v4.0.0 起）

- 不认识的参数就是错：打一句 `ERR 未知参数：…（用 --help 查看用法）`，`exit 1`。**不许**加「旧写法自动改写」「静默忽略」「跨版本提示」那一套。
- 破坏性变更写进提交信息与发布说明的人话里即可，脚本内不再维护登记表。
- 因此 `--help` / `--version` / 无参数 / `--bogus` 四个快速用例只看 rc：认识的 `0`，不认识的 `1`。

---

## 8. 文档规则

- **下载地址用 `releases/latest/download/` 或固定 tag，不许用 `raw.githubusercontent.com` + `/main/`。**
  - raw 在国内实测多次 8 秒超时；
  - `/main/` 会让使用者跟着**未发布**的中间状态跑。
- **`-L` 不能省。** `releases/latest/download/` 返回 302，不带 `-L` 时 `curl -f` 报 `(22)`。
- **`cdn.jsdelivr.net` 不要用于本仓库。** 实测返回缓存旧版本（`@main` 拿到过 `VERSION=6.0.0` 的历史内容）。
- 加速源（`gh-proxy.com`、`ghproxy.net`、自建）能代理 Release 资产，但会**偶发 403/522**，同一地址几分钟后即 200。
- Markdown 表格每行必须以 `|` 开头独立成行，**不许把多行挤成一行**（`| a | ... || b | ...` 会让表格塌掉）。
- 帮助文本在 `cat <<'USAGE'`（带引号 heredoc）里，**变量不会展开**，不许在里面写 `$VERSION`。
- 文档里承诺的行为必须与源码一致。特别是不许写「脚本每次运行都会把版本号写进日志」而 `log()` 并不打印版本号——要么改文档，要么改代码。

### 8.5 历史：引导器 `ct-bootstrap.sh`（v3.0.0 已取消）

v3.0.0 起不再有引导器：整套脚本不到 50KB，计划任务里「下载 → 校验 → 执行」八行就够，缓存与版本探测都没有价值。以下约束只对 v2.x 及更早的版本成立，留作**历史教训**——新装法仍然守同样的两条底线：

- **绝不允许「静默成功」**：下载失败只能「沿用上一轮通过校验的副本」或报错退出（`ERR 拿不到可用的更新脚本` + `rc=1`）。「探测失败就当没有新版本、然后 exit 0」这种写法会让使用者以为更新成功。
- **下到的东西必须先校验再执行**：字节数 > 1000、`sh -n` 通过、含特征串 `container-autoupdate`。只做 `sh -n` 是不够的：一行 `garbage` 也能过语法检查，然后被当成脚本执行（实测报 `line 1: garbage: not found`，rc=127）；`gh-proxy.net` 还会返回 195 字节的 HTML 跳转页（`rc=0`，内容完全不是脚本）。
- 旧引导器踩过的具体坑（探测窗口被 `VERSION=` 行的下移顶出 4KB、`sed` 捕获组漏反斜杠导致版本号恒为空、`api.github.com` 限流、自建源偶发 40s 超时）随它一起作废，不必在新代码里复刻。

> 现行装法有四处同步副本：`README.md` 的「安装（DPanel 计划任务）」代码块、`docs/advanced-usage.md` 的计划任务段、脚本 `usage()` 的示例段（多两格缩进）、`scripts/gen-release-notes.sh` 生成的那段。改了任何一处，其余三处必须内容一致。

### 8.6 文档只维护中文版

用户文档只有中文一份，**没有英文副本**（早期有过 `*.en.md`，已全部删除；`scripts/check-docs.py` 会拦住重新加回来）：

| 文件 | 内容 |
|---|---|
| `README.md` | 入口：定位、安装、两种模式、参数与环境变量、回滚、退出码 |
| `docs/how-it-works.md` | 一轮做什么、失败会怎样、保护不了什么 |
| `docs/parameters.md` | 参数表、环境变量表、退出码表 |
| `docs/advanced-usage.md` | 计划任务写法、手动跑、多项目、排查、FAQ |
| `docs/releasing.md` | 发版流程、资产、发版后核对 |

MUST

- **只改中文版**，不新建 `*.en.md`（`scripts/check-docs.py` 会直接报错）。
- **文档要短**：能给一行就不要写一段，能删的小节就删。这个项目只有一个用户，读者是维护者本人。
- **代码标识符原样**：参数名、环境变量名、文件名、tag、镜像名、`VERSION` 用反引号包起来，不翻译。
- **脚本真实输出的中文日志原样照抄**，不要改写成「友好文案」——排查时要能按原文 grep。
- **一致性由 `scripts/check-docs.py` 把关**（CI 的「文档检查」步骤会跑它）：本地链接与锚点、表格结构、CRLF、有没有残留的英文副本。
  - 改了用户文档 → 本地先跑 `python3 scripts/check-docs.py .`，必须 0 问题再提交。
- **帮助文本（`--help`）与文档必须一致**：参数、环境变量、退出码三处最容易不同步。

NEVER

- **不许翻译 `AGENTS.md`**（维护者内部规则，保持中文）。
- **不许翻译脚本里的注释**（`container-autoupdate.sh` 与 `scripts/*.sh` 的注释一律中文）。
- **不许为了「以后可能有人看」把文档写长**：没有第二个用户，长文档只会先过期。
---

## 9. 提交与发版

### 9.1 发版链路

```
改 VERSION → 提交到 main → Actions 自动打 tag + 发布 Release
```

- `release.yml` 只在 `main` 上发版（`on.push.branches=[main]` + job 里 `if: github.ref == 'refs/heads/main'`）。
- 其他分支与 PR 走 `ci.yml`，只校验不发版。
- 工作流幂等，但**判定条件是「tag 与 Release 都存在」**，不是只看 tag：Release 那步失败过（`gh release create` 偶发失败）、tag 却已经推上去时，只判 tag 会永远 skip，这个版本就再也发不出去（v4.0.2 实测踩到）。现在 tag 已存在时「打 tag」步跳过、「发布 Release」步带 4 次重试补发。
- 发布说明由 `scripts/gen-release-notes.sh` 自动生成（定位句 + 提交列表 + 安装那段 + sha256）。

### 9.2 改了脚本却不改 VERSION 的后果

`releases/latest/download/` 会继续提供**旧**资产，而 HEAD 已不同 → 「本地 = HEAD = 资产 = 线上」这条不变量被打破，用户下载到的是旧代码。

**结论：改了 `container-autoupdate.sh` 就必须按 §7.2 升 `VERSION`。**

### 9.3 推送后必须做端到端核对

```sh
# 三方 sha256 必须完全相同
sha256sum container-autoupdate.sh                       # 本地
git show HEAD:container-autoupdate.sh | sha256sum       # git HEAD（走 Python 读原始字节）
curl -fsSL -L <releases/latest/download/...> | sha256sum # 线上实际下载
```

再跑一次 `sh <下载的文件> --version` 确认版本号。

### 9.4 提交信息

`type: 一句话说明`（`feat` / `fix` / `docs` / `chore` / `refactor`）。破坏性变更在正文里写清「从 vX 起改成什么」。

---

## 10. 陷阱速查表

| 现象 | 根因 | 对策 |
|---|---|---|
| `sh: syntax error: unexpected "("` | PowerShell 剥掉了 ssh 的内层引号 | 落地 `.sh` 文件再执行 |
| `do\r: syntax error` | 文件是 CRLF | `WriteAllText` + 替换为 LF，核对 CR=0 |
| `git push` 报 exit 1 但其实成功 | stderr 的 `To https://...` | 用 `rev-parse` 比对 sha |
| 「仓库里存的是 CRLF」 | PowerShell 管道重编码 | 用 Python 读原始字节 |
| `page not found` | API 路径没带 `/v1.47/` | 带版本前缀 |
| `invalid date '%T'` | 引号被剥，`date "+..."` 变形 | 落地脚本 |
| 正常拉取被判「digest 不一致」 | 拿开头快照比对，上游在拉取期间发新版 | 用拉取流里的 `"status":"Digest: ..."` |
| 回滚点凭空消失 | pull 之前就移动了 `:prev` | 用 `:rollback-pending` 占位，健康后才移 |
| 容器跑旧镜像但 `:latest` 是新镜像 | 中止路径没还原 tag | `abort_tags` |
| busybox 算术算出荒谬的天数 | `$(( 2026-31 ))` 把日期当算式 | `date -d` 转 epoch 再减 |
| `--compose a --container b` 静默通过 | 两个分支各自清空对方变量，变成「后者胜出」 | `parse_args` 里用 `_SAW_COMPOSE`/`_SAW_CONTAINER` 标志位，循环后判两者同为 1 则 `exit 1` |
| awk 脚本静默不生效 | 用了 `\s` / `\x27`（POSIX awk 不保证，mawk 不支持） | `[[:space:]]`、`sprintf("%c",39)` |
| `curl \| sh` 下载失败却 rc=0 | 管道吞掉了 curl 的失败 | `mktemp` 落地再 `sh "$_t"`，或 `( A \|\| B ) \| sh` |
| `A \|\| B \| sh` 什么都不执行 | A 成功时输出被丢弃 | 必须加括号 |
| `set -o pipefail` 下 `--version` 返回 23 | 脚本提前退出，curl 写管道失败 | pipefail 只用于「会跑完整个流程」的固定参数场景 |
| DPanel 日志只有一行 `signal: killed` | 被 SIGKILL，message 为空串 | 内部超时远小于 `scriptRunTimeout` |
| DPanel 任务脚本被清空 | `POST /common/cron/create` 返回 500 会清空字段 | 直改 SQLite，改前备份 |
| DPanel 任务丢了 `scriptRunTimeout` | UI 编辑时重写 setting JSON，`omitempty` 键被抹掉 | 每次 UI 编辑后回读确认 |
| 表格塌成一行 | 多行被合并 | 每行独立 |
| 发版后用户拿到旧代码 | 改了脚本没升 VERSION | 必升 VERSION，并做 §9.3 三方核对 |
| （历史 v3.0.0 前）引导器把一行垃圾当成脚本执行 | 只用 `sh -n` 校验，垃圾也能过语法 | 四道校验：`sh -n` + 能解析 `VERSION` + 特征串 + 字节数 > 1000（新装法保留其中三道） |
| （历史 v3.0.0 前）引导器版本号恒为空 | `sed` 捕获组写成 `(...)` 而非 `\(...\)` | 改回 `\(...\)`（引导器已删，教训仍有效：正则捕获组别漏反斜杠） |
| （历史 v3.0.0 前）引导器探测失败却 rc=0 | 把「探测失败」当成「没有新版本」 | 只能回退到合格缓存或 `die`（新装法同理：拿不到可用脚本必须 `rc=1`） |
| （历史 v3.0.0 前）引导器 Range 探测很慢 | 用了直连或 `api.github.com` | 自建站 `github.mus.pp.ua` 优先、公共站 `gh-proxy.com` 兜底；API 会限流 |
| （历史 v3.0.0 前）引导器「探测远端版本失败（网络问题）」但网络其实正常 | 探测窗口没盖住 `VERSION=` 那行（它会随脚本变长下移） | 窗口放大到 16KB；Range 成功却没解析出版本号时，把整文件取下来再解析一次 |
| 拉取最后卡在「层都拉完了」被判卡死，daemon 报 `context canceled` | Docker 写镜像配置期间不吐字节，被当成停滞掐掉，已下载的层全作废 | 层拉完后进收尾宽限（`T_STALL_FINISH`）；放弃前先问 daemon 镜像是否已落盘 |
| DPanel CLI 明明失败了，脚本却报成功 | 用 CLI 退出码判成败，而失败时退出码仍是 0（容器不存在、项目未登记、镜像清单读不到） | 解析 JSON：`code` ≥ 400 或 `status=failed` 或 `error` 非空才算失败 |
| 反过来：DPanel 成功了却被判失败 | 成功的形状（`{"name":"..."}`、`{"containerId":"..."}`）**没有 `code` 字段** | 没有 `code` 不是失败信号 |
| （v2.0.0 历史）`compose:deploy` 跑完镜像没变，却报成功 | `--pull-image` 默认是 `command`，那条路不拉新镜像 | 显式 `--pull-image dpanel`（v2.1.0 起 Compose 不再走 DPanel，已无此坑） |
| Compose 明明重建了容器，却报「新建」 | 快照按**容器 ID** 当键，而 `up -d` 重建后 ID 会变，旧的删了、新的没见过 | 快照一律按**容器名**当键（N1 真机实测踩到：报的是 `新建：…` 而不是 `已重建：…`） |
| Compose 报「已是最新」，可容器明明是新起的 | 把「部署前没有这个容器」当成「没变化」 | 分三态报告：`已重建` / `新建` / `已是最新`，谁都不许并进别人 |
| Compose 反查不到项目目录 | 项目从没部署过、容器已被 `down`、或项目名写错 | 用 `--compose-dir` 指目录，或先手动 `docker compose up -d` 一次 |
| 造假旧镜像起不来（`exec: "sleep": … not found`、`stat /bin/busybox: …`） | `docker export`/`import` 丢镜像配置；未启动的容器导出的 rootfs 是空的 | 别用 export/import：`docker pull` 一个真实旧标签顶掉 tag（见 §6.2） |
| `docker compose` 不可用 | 缺 Compose v2 插件（或只有 v1 的 `docker-compose`） | `check_deps` 里显式 `docker compose version`，缺就报错退出 1 |
| DPanel 的结果 JSON 解析不到 | 要么加了 `-q`（结果被一起吞掉），要么取了第一行而不是最后一行 | 不加 `-q`；取 stdout 里**最后一个**以 `{` 开头的行 |
| DPanel 的报错只剩半句话 | 用「到逗号为止」的方式取值，而错误文本里就有逗号 | 字符串值先按 `"key":"..."` 整串匹配，匹配不到再退数字/布尔 |
| 不认识的参数被静默忽略 | `parse_args` 没有兜底的「未知参数」分支 | `*` 分支必须报错并 `exit 1` |
| 计划任务里只有一句 `exit status 1` | 失败原因只写了 stdout，而 DPanel 失败时只保留 stderr | 把 `ERR`/`CRITICAL` 行与紧随的缩进补充行写进真 stderr |
| 预算不足那类失败照样只剩 `exit status 1` | 那句是 `WARN` 开头的，而 `log()` 只按 `ERR`/`CRITICAL` 前缀分流入 stderr；且 `EXIT_CODE=1` 写在 `log` **之后**，判失败时已经来不及 | `log()` 里让 `WARN` 也看 `EXIT_CODE`：已判失败就进 stderr；相关调用点把 `EXIT_CODE=1` 提到 `log` 之前（v4.0.3） |
| 每轮都重建容器 | 跳过了「先检查后升级」 | 先不带 `--upgrade` 调一次，`upgrade` 为 true 才真升级 |
| 升级后没有回滚点 | 传了 `--disable-bak` | 不许传它：`<容器名>-bak-<时间戳>` 就是回滚点 |
| `releases/latest/download/ct-stale-lock-check.sh` 404 | Release 只传了主脚本 | 两个资产都要传（v3.0.0 起没有引导器） |
| 每成功更新一次就留下一个完整 `<none>` 镜像 | `docker compose pull` 把标签搬到新镜像，`up -d` 去掉最后引用，而 v2.0.0 删掉 `clean_orphans` 后没有人回收（N1 实测两条各占 64MB 独有层） | Compose 分支部署成功后回收，三条约束见 §3 MUST（v5.0.0） |
| 想清 `<none>` 一跑 `docker image prune` 就把别的项目的 dangling 也删了 | prune 不带 `-a` 是「专删本机所有 dangling」，它不认识「这个镜像属于哪个项目」 | 先按 `.RepoDigests` 认归属，再排除有容器引用的，用不带 `-f` 的 `docker rmi` |
| 回收把别的项目的镜像删了 | 按 `repo:tag` 前缀判归属 —— 变 `<none>` 后 `Repository` 字段是 `<none>`，只能靠 `.RepoDigests` | 归属只认 `.RepoDigests` 与本站项目仓库名精确比对（`grep -Fxq`） |
| 日志里算出的短 id 少一位、前面多一个空格 | 把空格分隔的列表整个喂给 `_short_id`，`substr` 把前导空格也算进去了 | `_short_id` 先 `gsub` 剪首尾空白再截断；列表多元素时逐个转再拼 |

---

## 11. 提交前检查清单

- [ ] `sh -n container-autoupdate.sh` 通过
- [ ] `sh -n scripts/gen-release-notes.sh` 通过
- [ ] `sh -n scripts/ct-stale-lock-check.sh` 通过
- [ ] 三个 `.sh` 的 CR 计数为 0（`container-autoupdate.sh` 与 `scripts/*.sh`）
- [ ] 改了脚本 → `VERSION` 已按 §7.2 升级
- [ ] 不认识的参数 → `rc=1` 并点名（没有兼容层；不认识的环境变量会被忽略、不报错，不要靠设旧 env 来「测拦截」，见 §6.5）
- [ ] `--help`、`--version`、无参数、`--bogus` 四个快速用例行为正确（认识的 0，不认识的 1）
- [ ] 至少跑了 §6.1 里受影响的那几行场景，并贴出真实输出
- [ ] 测试容器 / 镜像 / 状态目录已清理，生产已复原且 `healthy`
- [ ] 文档里没有新增硬编码的当前版本号
- [ ] 下载地址是 `releases/...`，带 `-L`，没用 jsdelivr
- [ ] 三个 `.sh` 在 git 里的权限都是 `100755`（`git ls-files -s`）
- [ ] 推送后做了 §9.3 的三方 sha256 核对
- [ ] 改了用户文档 → 跑过 `python3 scripts/check-docs.py .`（链接与锚点、表格、CRLF、没有 `*.en.md`）
- [ ] 改过 `log()` 或错误输出路径 → 跑过 stdout/stderr 分流实测（`sh 脚本 >out 2>err`），确认 `ERR`/`CRITICAL` 行与缩进补充行都在 stderr 里，**且「伴随失败的 `WARN`」也在 stderr 里、纯提示的 `WARN` 不在**（两侧都要验：预算不足 vs `config` 读不出清单）
- [ ] 新增的「会失败的关键查询」（如查远端 digest）→ 有重试，且重试次数在日志里写明
- [ ] 改过拉取的停滞/收尾判定 → 复跑「层拉完后长时间静默」场景（不进普通卡死判定），且**放弃之前**问过 daemon 镜像是否已落盘
- [ ] 改过失败原因的打印位置 → 同一句失败原因在 stdout 与 stderr 里**各只出现一次**（stdout 完整日志 + stderr 给计划任务看是两回事，不许当成重复）

v2.1.0 起另外还要过这几条：

- [ ] **容器模式**的更新动作没有在脚本里重新实现（仍只调 `container:upgrade`；没有新的 pull / create / 健康门禁 / `:prev` 代码）
- [ ] **Compose 模式**只调 `docker compose pull` 与 `docker compose up -d`，没有手工 `tag`/`create`/`rm`，也没有 `--remove-orphans`
- [ ] compose 参数仍走 `COMPOSE_PROJECT_NAME` / `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` / `COMPOSE_ENV_FILES`（没拼成命令行）
- [ ] `pull` 失败时**没有**继续执行 `up -d`（测试里有断言）
- [ ] 报告分得清三态：`已重建` / `新建` / `已是最新`，且**快照按容器名当键**（按 ID 会把重建误判成新建，N1 真机踩过）
- [ ] `--compose-dir` 与 `COMPOSE_DIR` **恢复可用**（不再被当成已移除的旧写法），`T_INSPECT` 仍被接受
- [ ] `DP_T_PULL` / `DP_T_UP` / `DP_T_CHECK` / `DP_T_UPGRADE` 都**按剩余预算重新收敛**（不是直接用配置值）
- [ ] 判 DPanel 成败是**解析 JSON**，不是看退出码；「没有 `code` 字段」没有被当成失败
- [ ] 容器模式仍然**先检查后升级**，且没有 `--disable-bak`、没有 `-q` / `--quiet`
- [ ] 取结果用的是「stdout 最后一个以 `{` 开头的行」，取字符串字段不会被逗号截断
- [ ] 没有把兼容层加回来（§7.3）：旧写法就是 `rc=1`，没有改写、没有提示表
- [ ] `docker compose version` 在 `check_deps` 里被显式检查（缺 v2 插件要报清楚，别让人以为是网络问题）
- [ ] N1 真机跑过**两条路**：Compose（标签反查目录 → pull → up -d → 三态报告）与容器模式（容器内直执 + `docker exec` 各一次），并贴出真实输出
- [ ] 测试留下的 `<容器名>-bak-<时间戳>` 备份容器、被顶掉的镜像 tag、`compose-*` 事务残留都已清干净
- [ ] N1 上的测试脚本与临时文件（容器内 `/tmp/...`、宿主 `/tmp/...`）已删

v3.0.0 起另外还要过这几条：

- [ ] 仓库里**没有** `ct-bootstrap.sh`（CI 里有 `test ! -e ct-bootstrap.sh` 守卫；Release 只发两个资产）
- [ ] 计划任务的装法保持四处副本内容一致：`README.md`、`docs/advanced-usage.md`、脚本 `usage()` 示例段、`scripts/gen-release-notes.sh` 生成段（改了任何一处就同步其余三处）
- [ ] 那段装法仍然守两条底线：下载失败**不许静默成功**（沿用上一轮通过校验的副本，或 `ERR` + `rc=1`）；下到的东西**先校验再执行**（字节数 > 1000、`sh -n`、含 `container-autoupdate` 特征串）
- [ ] 没有把 `curl ... | sh` 写进任何文档或示例（管道会吞掉下载失败）
- [ ] `--ct-*` 任何形态都 `rc=1` 并点名；`CT_*` 环境变量会被忽略、不报错（v4.0.0 没有兼容层）
- [ ] 文档里锁版本的写法是**带 tag 的下载地址**（`releases/download/vX.Y.Z/…`），不是 `--ct-version`
- [ ] 文档里没有残留「引导器 / ct-bootstrap / 缓存目录 / `--ct-*` 表」的现行说法（只允许出现在「v3.0.0 迁移」段与 AGENTS.md 的§8.5 历史节）

v5.0.0 起另外还要过这几条：

- [ ] 回收只发生在**项目健康**（`up -d` 成功且容器都在跑）且剩余预算 ≥ 20 秒时；`pull` 失败 / `up -d` 失败 / `--dry-run` / 预算不足四条路径都**没有**碰过镜像
- [ ] 归属只认 `.RepoDigests`（`repo:tag` 前缀不足以认出已经变 `<none>` 的旧镜像；本地 build/import 的没有 RepoDigests，必须留着）
- [ ] **没有**任何「保留回滚点」逻辑（没有 `_keep`、没有按 `.Created` 留最新一个）：`up -d` 成功后本轮淘汰下来的旧镜像整批回收
- [ ] 删除用不带 `-f` 的 `docker rmi`（有引用时 daemon 自己拒绝），**没有** `docker image prune`
- [ ] N1 真机跑过靠容器回收的端到端场景（`dpanel` 容器内执行），并贴出真实输出：`回收旧镜像 N 个（已无标签、无容器引用，本项目归属）`、本轮旧镜像**确实被删**（不是「保留一个」）、别的项目的 dangling 未被动过、生产容器未被重建
- [ ] 文档里没有残留「旧镜像被刻意保留当回滚点」的说法；Compose 回滚一律写成「把 compose 文件里的 `image:` 钉回旧 tag/digest 再跑一轮」
