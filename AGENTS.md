# AGENTS.md —— 修改本仓库的硬性规则

面向在本仓库动手的 **AI 代理与人类维护者**。

这些规则不是风格偏好，每一条都对应一次真实的失败：某个命令炸了、某个「已验证」其实是假的、某个回滚点被悄悄删掉、某个 Release 资产和 HEAD 不一致。**与个人习惯冲突时，以本文件为准。**

---

## 0. 动手前先读

| 读什么 | 为什么 |
|---|---|
| `container-autoupdate.sh` 头部注释 | 安全原则的原始表述 |
| `container-autoupdate.sh` 的 `BREAKING_TABLE` | 判断你的改动是否破坏兼容 |
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

### MUST

- **Compose 参数必须通过环境变量传**（`COMPOSE_PROJECT_NAME` / `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` / `COMPOSE_ENV_FILES`），保留原有的项目名、config 文件、env 文件。不许拼成命令行字符串（见下方 NEVER 第 3 条）。
- **不使用 `--remove-orphans`**：它会删掉不在当前 compose 文件里的容器，属于数据事故。
- **`:prev` 只能在健康门禁通过之后才移动。** 更新期间用 `<repo>:rollback-pending` 占位。
- **回滚必须用 `$OLD_IMGID`**，不许依赖 `:prev`（`:prev` 可能已被上一轮移动）。
- **中止路径必须把 tag 还原成更新前的镜像**（`abort_tags`）。否则 `:latest` 指向新镜像而容器还跑旧镜像，状态错位——此后任何一次手工 / DPanel 触发的重建都会把容器拉到**没经过健康门禁**的版本上。
- **拉取只 kill 本轮自己的 PID**，不许 `pkill` 按名字通杀（会杀掉别的并发任务）。
- **后台起子进程时 `$!` 只是那个子 shell 的 PID**，它 fork 出来的真正的进程（curl 等）`kill -9` 不到。要用 `--max-time` 之类给真实进程兜底，别指望 kill 能连坐。（v0.4.0 的真实故障：拉取用的 curl 活过了脚本，替主脚本一直占着锁。）
- **脚本内部不加互斥锁**：并发由 DPanel 计划任务保证，同一目标只挂一个计划任务。旧版的锁用 `exec 9>lock; flock -n 9` 持有，fd 9 会被子进程继承，残留的子进程能把锁长期占住，导致之后每一轮都 `SKIP` 并退出 0（生产上真实发生过：连续三轮日志完全一样）。已移除。
- **拉取失败的重试必须先分类，再决定要不要重试**：只有**瞬时**失败（网络抖动、429、5xx、拉取流中途断开）才重试；**永久**失败（镜像/仓库不存在、鉴权失败）与**卡死**（`T_STALL` 内没有新字节）不重试——重试一万次也一样，只是把时间预算耗光。分类依据是**拉取流自己报告的 `error` 字段**，不是 curl 的退出码：镜像源明确说「manifest unknown」时 curl 往往同时以非 0 退出，先看退出码就会把永久失败误判成瞬时故障。
- **坏版本 TTL 按「钉住时间」计算**（`date -d` 转 epoch），不许用镜像 `Created` 时间当锚点。
- **容器分支按容器 ID 操作**（不是名字），失败可恢复。
- **容器分支不把运行态 `NetworkSettings` 整包回投**；按声明式字段重建网络。
- **实际挂载（含匿名卷真实名称）转成显式 `Mounts`**，避免重复挂载和换卷。
- **创建后、启动前先做完整规格校验**（签名比对），不一致就别启动。

### NEVER

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

### 必须跳过的形态（并说明原因，不许硬上）

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

## 4. 拉取与进度判定

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
- 健康门禁在剩余预算不足时要**提前跳出并回滚**，不许把时间耗光。

---

## 6. 测试规则

### 6.1 必须覆盖的场景矩阵

| 场景 | 期望 |
|---|---|
| 正常更新（两种分支各一次） | 容器与 `:latest` 一致、`:prev` = 上一版 |
| 配置二选一（都填 / 都不填 / 名字不存在） | `rc=1`，不动任何东西 |
| 远端取不到 | 零变化 |
| 拉取停滞 | kill + 零变化 |
| 新版不健康 | 自动回滚，容器 ID 与旧镜像完全复原 |
| 校验中止 | tag 已还原、`:prev` 未动、`rollback-pending` 已清 |
| `--dry-run` | 什么都没改 |

### 6.2 制造「有新版本」的正确方法

**必须让容器本身回落到旧镜像**，只移动 `:latest` 标签无效——脚本的「本地版本」以容器实际运行的 `.Image` 为准（这是正确行为，不是 bug）。正确做法：

```sh
OLDID=$(docker image inspect -f '{{.Id}}' "$REPO:prev")
docker tag "$OLDID" "$REPO:latest"
docker compose up -d --force-recreate        # 让容器真的回到旧镜像
```

### 6.3 打桩方式

- 用 `awk` 改行，**不要用 `sed`**：`sed` 替换里带 `(`/`|` 等字符会报 `bad option in substitution expression`。
- 桩要改「行为」而不是「文案」，桩完必须验证 `sh -n`。

### 6.4 测试脚本自己的断言也会过期

曾把「脚本正确」误判成失败：断言里用的期望值在脚本启动时就采集了，而脚本钉 `:bad` 用的是**回滚那一刻**刚拉到的版本。看到失败先怀疑断言，再怀疑脚本。

### 6.5 测完必须复原

- 删掉所有测试容器（含 `__old_*` 副本）、测试镜像标签、测试状态目录。
- 复原被测试动过的生产状态：容器镜像与 `:latest` 一致、`:prev` 指向正确版本、无残留 `rollback-pending`。
- 确认生产容器仍 `healthy`。

---

## 7. 破坏性变更与版本

### 7.1 `VERSION` 是唯一版本来源

- 不许在别处（脚本头部注释、usage 文本、文档示例）**硬编码当前版本号**——会过时。例外：文档里「锁死版本」的示例。
- `VERSION` 只能含数字和点，不带 `v` 前缀（工作流会拦）。

### 7.2 什么必须登记进 `BREAKING_TABLE`

**只要会让用户已有的调用方式失效，就必须登记**：

| 类别 | 例子 |
|---|---|
| `flag` | 命令行参数被移除 / 改名 |
| `env` | 环境变量被移除 / 改名 |
| `behavior` | 默认行为或语义变化 |

**不登记**：新增参数、改日志措辞、改内部实现。

> 没登记的破坏性变更对使用者是**完全静默**的。这是本仓库最容易犯的错。

### 7.3 版本号怎么升

| 改动性质 | 版本段 |
|---|---|
| 修 bug、改文案、补日志 | patch |
| 加参数 / 加能力，向后兼容 | minor |
| 改默认行为、用户需改配置 | major 段 |

### 7.4 三道防线不许拆

1. `flag`/`env` 命中 → 立即中止，`exit 3`，给出新写法与迁移方式。
2. `behavior` → 跨版本 `WARN`（记住每个目标上次跑过的版本）+ `--compat <版本>` 硬停。
3. 退出码 `3` 必须与「未知参数」的 `1` 区分开。

`compat_state_dir()` 的目录**必须与事务目录分开**。曾与 `C_WORK` 同路径，而收尾会 `rm -rf "$C_WORK"`，导致 `lastver` 每轮被删、跨版本提示永远不触发。

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

### 8.5 引导器 `ct-bootstrap.sh` 的硬性约束

引导器是**使用者实际运行的东西**，它的错误比主脚本的错误更致命（主脚本至少还会自己校验参数）。改动它必须守住下面几条：

- **不许把「探测失败」当成「没有新版本」。** 探测失败时只能走两条路：回退到通过 `verify_file` 的本地缓存，或 `die`（非 0）。**绝不允许静默地「什么都不做然后 exit 0」**——使用者会以为更新成功。
- **缓存文件必须四道校验后才能执行**：`sh -n` 语法 + `file_version` 能解析出 `VERSION` + 含特征串 `container-autoupdate` + 字节数 > 1000。
  只做 `sh -n` 是不够的：`garbage` 这种一行垃圾也能通过 `sh -n`，然后被当成脚本执行（实测报 `line 1: garbage: not found`，rc=127）。
- **`sed` 的捕获组必须写成 `\(...\)`**，不是 `(...)`。曾漏了反斜杠导致版本号恒为空，连带让上面的坏包校验全部失效。
- **探测只用 Range 取前 4KB**（`curl -r 0-4000`），不要为此下载整个文件。`VERSION` 在文件第 53 行，4KB 足够。
  - 不要用 `HEAD` 读 302 的 `Location`：直连要 12 秒，代理根本不返回 `Location`。
  - 不要用 `api.github.com/releases/latest`：会限流（`API rate limit exceeded`）。
- **默认源顺序是 `gh-proxy.com` → 直连 → `ghproxy.net`**，依据是实测：
  | 源 | Range 探测 | 完整下载 |
  |---|---|---|
  | `gh-proxy.com` | 1~2s，3/3 成功 | 1s |
  | 直连 `github.com` | 1s，但 3 次中 1 次 DNS 失败 | 不稳 |
  | `ghproxy.net` | **3/3 全部 15s 超时** | — |
- **自建源 `github.mus.pp.ua` 不进默认列表。** 实测 8 次里 Range 成功 5 次、下载成功 4 次，平均 12~20s；根因是它把请求转给 GitHub **网页前端**（响应头 `content-type: text/html` + `set-cookie`），不是直转 Release 资产。它内容正确（sha256 与官方一致），使用者可用 `CT_SOURCE` 自行接入，但不该是默认。
- **固定版本模式（`--ct-version` / `CT_VERSION` 非空）必须完全不联网**，这是它存在的唯一理由。引导器自己的开关用 `--ct-*`（命令行优先于同名 `CT_*` 环境变量），其余参数原样透传给主脚本。
- **改了 `ct-bootstrap.sh` 也要升 `VERSION` 并发布**，因为 Release 必须同时上传 `container-autoupdate.sh` 和 `ct-bootstrap.sh` 两个资产；少传一个，`releases/latest/download/ct-bootstrap.sh` 就是 404。

### 8.6 用户文档必须中英文同步

用户文档有**两个版本**：中文（默认）与英文副本。

| 中文（默认） | 英文副本 |
|---|---|
| `README.md` | `README.en.md` |
| `docs/how-it-works.md` | `docs/how-it-works.en.md` |
| `docs/parameters.md` | `docs/parameters.en.md` |
| `docs/advanced-usage.md` | `docs/advanced-usage.en.md` |
| `docs/releasing.md` | `docs/releasing.en.md` |

MUST

- **改了一份就必须同步另一份**，包括内容改动与新增章节。中文是默认入口，英文是副本，两者内容必须一致。
- **每份文档的 H1 正下方放语言切换条**，链接到本文件与另一语言版本：
  中文版 `> 语言：[中文](README.md) | [English](README.en.md)`；
  英文版 `> Language: [English](README.en.md) | [中文](README.md)`。
- **英文文档里的本地链接必须指向英文文件**，锚点要按英文标题重算（GitHub 规则：小写、空格→连字符、去掉反引号/括号/点）。链接指向的文件不存在、锚点对不上标题 ⇒ 文档坏掉。
- **代码标识符不翻译**：参数名、环境变量名、文件名、tag、镜像名、`BREAKING_TABLE`、`VERSION` 等一律原样，用反引号包起来。
- **脚本真实输出的中文日志原样保留**，在代码块末尾补 `→` 开头的英文对照行；不要逐行夹杂英文。
- **术语必须一致**（同一概念在所有英文文档里用同一个词）：DPanel 计划任务 → DPanel scheduled task；引导器 → bootstrapper；互斥锁 → mutex lock；健康门禁 → health gate；回滚点 → rollback point；演练 → dry run；退出码 → exit code；破坏性变更 → breaking change；迁移方式 → migration path；跨版本提示 → cross-version notice。
- **英文文档里不许残留中文**，除了：脚本日志原文、代码标识符、切换条里的「中文」二字。
  - 脚本日志原文在英文文档里也**要用反引号包起来**（正文中引用日志文本时），免得被当成未翻译的中文残留。
- **一致性由 `scripts/check-docs.py` 把关**（CI 的「文档检查」步骤会跑它）：语言切换条、本地链接与锚点、表格结构、CRLF、中英标题数量与层级。
  - 改了用户文档 → 本地先跑 `python3 scripts/check-docs.py .`，必须 0 问题再提交。
  - 脚本的检查是**底线**，不是全部：它查不出「翻译得不准」「术语不一致」，那部分靠人工。

NEVER

- **不许翻译 `AGENTS.md`**（维护者内部规则，保持中文）。
- **不许翻译脚本里的注释**（`container-autoupdate.sh` / `ct-bootstrap.sh` 的注释一律中文，本次只做文档）。
- **不许只在英文版里加新内容**——中文版缺了内容 = 面向中文用户的文档残缺。

---

## 9. 提交与发版

### 9.1 发版链路

```
改 VERSION → 提交到 main → Actions 自动打 tag + 发布 Release
```

- `release.yml` 只在 `main` 上发版（`on.push.branches=[main]` + job 里 `if: github.ref == 'refs/heads/main'`）。
- 其他分支与 PR 走 `ci.yml`，只校验不发版。
- 工作流幂等：tag / Release 已存在就跳过。
- 发布说明由 `scripts/gen-release-notes.sh` 自动生成（定位句 + 本版破坏性变更 + 提交列表 + 下载命令 + sha256）。

### 9.2 改了脚本却不改 VERSION 的后果

`releases/latest/download/` 会继续提供**旧**资产，而 HEAD 已不同 → 「本地 = HEAD = 资产 = 线上」这条不变量被打破，用户下载到的是旧代码。

**结论：改了 `container-autoupdate.sh` 就必须按 §7.3 升 `VERSION`。**

### 9.3 推送后必须做端到端核对

```sh
# 三方 sha1 必须完全相同
sha256sum container-autoupdate.sh                       # 本地
git show HEAD:container-autoupdate.sh | sha256sum       # git HEAD（走 Python 读原始字节）
curl -fsSL -L <releases/latest/download/...> | sha256sum # 线上实际下载
```

再跑一次 `sh <下载的文件> --version` 确认版本号。

### 9.4 提交信息

`type: 一句话说明`（`feat` / `fix` / `docs` / `chore` / `refactor`）。破坏性变更在正文里写清「从 vX 起改成什么」以及「是否已登记 `BREAKING_TABLE`」。

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
| 跨版本 `WARN` 从不触发 | `lastver` 目录与事务目录同路径被 `rm -rf` | 状态目录分开 |
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
| 引导器把一行垃圾当成脚本执行 | 只用 `sh -n` 校验，垃圾也能过语法 | 四道校验：`sh -n` + 能解析 `VERSION` + 特征串 + 字节数 > 1000 |
| 引导器版本号恒为空 | `sed` 捕获组写成 `(...)` 而非 `\(...\)` | 改回 `\(...\)` |
| 引导器探测失败却 rc=0 | 把「探测失败」当成「没有新版本」 | 只能回退到合格缓存或 `die` |
| 引导器 Range 探测很慢 | 用了直连或 `api.github.com` | `gh-proxy.com` 优先；API 会限流 |
| `releases/latest/download/ct-bootstrap.sh` 404 | Release 只传了主脚本 | 两个资产都要传 |

---

## 11. 提交前检查清单

- [ ] `sh -n container-autoupdate.sh` 通过
- [ ] `sh -n ct-bootstrap.sh` 通过
- [ ] `sh -n scripts/gen-release-notes.sh` 通过
- [ ] `sh -n scripts/ct-stale-lock-check.sh` 通过
- [ ] 四个 `.sh` 的 CR 计数为 0
- [ ] 改了脚本 → `VERSION` 已按 §7.3 升级
- [ ] 若含破坏性变更 → 已登记 `BREAKING_TABLE`，且类别（`flag`/`env`/`behavior`）选对
- [ ] `--help`、`--version`、无参数、`--bogus`、`--compat` 非法值 五个快速用例行为正确
- [ ] 至少跑了 §6.1 里受影响的那几行场景，并贴出真实输出
- [ ] 测试容器 / 镜像 / 状态目录已清理，生产已复原且 `healthy`
- [ ] 文档里没有新增硬编码的当前版本号
- [ ] 下载地址是 `releases/...`，带 `-L`，没用 jsdelivr
- [ ] 四个 `.sh` 在 git 里的权限都是 `100755`（`git ls-files -s`）
- [ ] 改了 `ct-bootstrap.sh` → 引导器 10 个场景（固定版本 / 命中缓存 / 有新版本 / 网络故障有缓存 / 无缓存 / 坏包 / 参数透传 / 缓存裁剪 / 强制更新）已复跑
- [ ] 推送后做了 §9.3 的三方 sha1 核对
- [ ] 改了用户文档 → 对应英文副本已同步（§8.6）
- [ ] 每份用户文档的 H1 正下方有语言切换条，中英互指
- [ ] 英文文档里的本地链接指向英文文件，且锚点与英文标题对得上（逐条核对过）
- [ ] 英文文档里除脚本日志原文/代码标识符/「中文」二字外没有残留中文
