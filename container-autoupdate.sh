#!/bin/sh
# ===========================================================================
# DPanel 定时任务自动更新脚本 —— 一轮更新逻辑，交给 DPanel 的「计划任务」
# 按固定周期触发。脚本本身不含更新频率逻辑：频率、启停、并发全归 DPanel 管。
# 手动运行也允许，但那是「跑一轮就结束」的单次更新，不建议再套 cron / systemd timer。
# 当前版本见 VERSION 字段，用 --version 查看。
#
# 目标二选一：一个 Compose 项目名，或一个容器名。可以用命令行参数、
# 环境变量或文件顶部配置区指定，三者等价，优先级：命令行 > 环境变量 > 配置区。
#
# ★ 本版本的更新动作分两条路：
#     容器          → 交给 DPanel `container:upgrade`（先检查，确实有新版本才升级）
#     Compose 项目  → 脚本自己调 `docker compose pull` + `docker compose up -d`
#   脚本自己只做三件事：
#     1) 判断这个目标有没有新版本（容器 = 问 DPanel；Compose = 拉取本身就是判断）；
#     2) 有的话执行更新（容器交给 DPanel；Compose 交给 docker compose）；
#     3) 把结果如实报出来（成功 / 失败 / 无需更新）。
#
# 为什么这么分：
#   · 容器更新交给 DPanel：重建一个容器要复刻的东西太多（网络、挂载、匿名卷、
#     资源限制、标签……），任何一处漏掉都是一次事故；而 DPanel 本来就是干这件事的，
#     它还有升级失败自动回滚（留下 <容器名>-bak-<时间戳> 备份容器）。
#   · Compose 更新直接用 docker compose：compose 自己就带着「哪些容器属于这个
#     项目、用哪个 compose 文件、怎么重建」的全部信息，`pull` + `up -d` 就是它的
#     标准做法；项目目录与文件还能从容器标签自动认出来，不需要用户配置，
#     也不需要项目先在 DPanel 里登记。
#   · 回滚点不再由脚本打 <仓库>:prev 标签自己维护，也就不会出现「回滚点被
#     清理逻辑误删」这类问题。
#   · 脚本从 1700 多行降到几百行，剩下的每一条都能一眼看懂、一眼验证。
#
# 旧镜像回收（v4.1.0 加回，v5.0.0 起不再保留回滚点；只作用于 Compose 分支）：
#   `docker compose pull` 会把 <仓库>:<标签>「搬家」到刚拉下来的新镜像上，旧镜像
#   因此丢掉最后一个标签，但层还完整留在磁盘上；紧接着 `up -d` 重建容器，旧镜像
#   连最后的引用也没了。v2.0.0 删掉 clean_orphans 之后没人回收，**每成功更新一次
#   就永久沉淀一个完整镜像**（N1 实测：magpie 每小时更新，两条 <none> 各占 64MB
#   独有层）。现在在 compose_update 末尾做一次「只删本项目、已无标签、无引用」的
#   回收，三条约束见 compose_reclaim 的注释。
#   **不保留回滚点**（v5.0.0 明确取舍）：v4.1.0 曾把「更新前在用的那个」留着当回滚点，
#   但那样稳态下每个 Compose 项目永远躺着一个 <none>，与「别堆积」自相矛盾。
#   代价是 Compose 模式不能再用 `docker tag <旧镜像ID>` 回退 —— 要回退只能把
#   compose 文件里的 tag 钉回旧版本，再跑一轮。
#   容器分支**不做**回收：那边 DPanel 的 <容器名>-bak-<时间戳> 备份容器就是回滚点，
#   它持有旧镜像的引用，旧镜像本来就不会变成 <none>；而且容器分支不许脚本写 Docker。
#
# 安全原则：
#   · 容器分支不写 Docker：变更动作只有 DPanel 一个执行者。
#     Compose 分支只用 compose 自己的 pull / up -d，不手工 tag、不手工 create。
#     唯一一处脚本亲手删的东西是「本项目自己淘汰下来的、已无标签无引用的旧镜像」，
#     部署成功后整批回收、不留回滚点（回退靠把 compose 文件里的 tag 钉回旧版本）。
#   · 失败原因同时落到真正的 stderr（计划任务失败时只收 stderr、丢弃 stdout）。
#   · 只检查不动手：--dry-run。
#   · 不做版本兼容层：不认识的参数就报错退出（rc=1），不猜、不静默忽略。
#     环境变量没有这层检查（不认识的名字会被忽略，不报错）。
#
# 注意：容器回滚只能恢复容器与镜像，不能撤销新程序已经做过的数据迁移。
# 生产数据库仍应另有备份。
# ===========================================================================
set -u
# 失败原因必须能落到「真正的 stderr」。
# 计划任务（DPanel）在任务失败时只保留 stderr、丢掉 stdout；如果失败原因只写在
# stdout 上，计划任务里就只剩一句「exit status 1」，排查时什么都看不到。
# 下面 exec 2>&1 会把 fd 2 指到 stdout，所以先把原来的 stderr 另存到 fd 3。
# 先探一下 stderr 能不能用：exec 的重定向失败会让非交互 shell 直接退出，
# stderr 被关掉的环境不能因此崩掉（探不到就退回用 stdout 报错）。
if ( : >&2 ) ; then
  exec 3>&2
  ERR_FD=3
else
  # stderr 根本用不了（被关掉了）：退回写 stdout。宁可重复也不让脚本崩掉。
  ERR_FD=1
fi
exec 2>&1

# ======================= 配置区（二选一）===================================
# 填 Compose 项目名 → 走 Compose 分支；填容器名 → 走容器分支。
# 两者必须且只能填一个。也可以不改这里，改用命令行参数或环境变量：
#   命令行    --compose <名> / --container <名>
#   环境变量  UPD_COMPOSE / UPD_CONTAINER
# 优先级：命令行 > 环境变量 > 这里的值。
COMPOSE_NAME=""
CONTAINER_NAME=""
# ===================== 配置区结束（以下不用改）=============================

[ -n "${UPD_COMPOSE:-}" ]   && COMPOSE_NAME="$UPD_COMPOSE"
[ -n "${UPD_CONTAINER:-}" ] && CONTAINER_NAME="$UPD_CONTAINER"

DOCKER_SOCK="${DOCKER_SOCK:-}"     # --docker-sock：传给 docker CLI（DOCKER_HOST）
# Compose 项目目录：可选。不给时脚本从现有容器的 compose 标签里反查
# （com.docker.compose.project.working_dir / .config_files），通常都不用填。
COMPOSE_DIR="${COMPOSE_DIR:-}"
# DPanel 的位置。脚本在 DPanel 容器里跑时最省事（直接执行二进制）；
# 在别处跑时脚本会用 `docker exec` 进 DPanel 容器执行，两者等价。
DPANEL_NAME="${DPANEL_NAME:-dpanel}"            # DPanel 容器名
DPANEL_BIN="${DPANEL_BIN:-/app/server/dpanel}"  # DPanel CLI 在容器里的路径
DPANEL_DOCKER_ENV="${DPANEL_DOCKER_ENV:-local}" # DPanel 里的 docker 环境名（对应它的「Docker 服务器」）

START=$(date +%s)
VERSION="5.0.1"
T_HARD="${T_HARD:-540}"            # 整轮时间硬上限（秒）
# 单次「检查」调用超时。T_INSPECT 是旧名字，继续认，方便老任务不改配置。
DP_T_CHECK="${DP_T_CHECK:-${T_INSPECT:-120}}"
DP_T_UPGRADE="${DP_T_UPGRADE:-420}"  # 单次「升级」调用超时（容器模式；实际还会被剩余预算收敛）
DP_T_PULL="${DP_T_PULL:-420}"        # Compose 模式：单次 `docker compose pull` 超时
DP_T_UP="${DP_T_UP:-180}"            # Compose 模式：单次 `docker compose up -d` 超时
DP_MIN_UPGRADE="${DP_MIN_UPGRADE:-90}" # 剩余预算低于这个值就不动手，避免被计划任务半路杀掉
DRY_RUN="${DRY_RUN:-0}"
EXIT_CODE=0

now()     { date +%s; }
elapsed() { echo $(( $(now) - START )); }
left()    { echo $(( T_HARD - $(elapsed) )); }

# ---- 错误原因同时落到真正的 stderr ----
# 计划任务（DPanel）在任务失败时只保留 stderr、丢掉 stdout。
# 所以失败原因不能只写在 stdout 上，否则计划任务里只剩一句「exit status 1」。
# 判定规则：消息以 ERR / CRITICAL 开头的算「错误行」；紧随错误行之后的缩进补充行
# （log "   ..."）属于同一个错误块，一起进 stderr。
# 用 _LOG_ERR 记住「上一个错误块是否还在延续」，不靠猜缩进。
#
# WARN 行要看本轮是不是已经判了失败（EXIT_CODE=1）：
#   · 判了 → 它就是这一轮的失败原因（例如「剩余时间不足，本轮不动手」），
#           必须和 ERR 一样进真 stderr，否则计划任务里只剩一句 exit status 1；
#   · 没判 → 它只是提示（例如 config 读不出镜像清单，流程照走），留在 stdout。
# 所以凡是「先 WARN 再 EXIT_CODE=1」的地方，都要把 EXIT_CODE=1 提到 log 之前。
_log_stderr() {
  if [ "${ERR_FD:-2}" = "3" ]; then
    echo "$1" >&3
  elif [ "${ERR_FD:-2}" = "1" ]; then
    echo "$1"
  else
    echo "$1" >&2
  fi
}
log() {
  _l="[$(date '+%F %T')] $*"
  echo "$_l"
  case "$*" in
    ERR\ *|CRITICAL\ *)
      _log_stderr "$_l"
      _LOG_ERR=1
      ;;
    WARN\ *)
      # 本轮已经判了失败 ⇒ 这句 WARN 就是失败原因，跟 ERR 一样进真 stderr，
      # 后面的缩进补充行（说明为什么不动作）也要跟着进去。
      # 还没判失败 ⇒ 只是提示，留在 stdout，也不打断上一个错误块。
      if [ "${EXIT_CODE:-0}" != "0" ]; then
        _log_stderr "$_l"
        _LOG_ERR=1
      else
        _LOG_ERR=0
      fi
      ;;
    "   "*)
      # 缩进补充行：属于上一个错误块时一起进 stderr。
      # 非缩进的普通日志行会清掉标记，错误块因此自然结束。
      if [ "${_LOG_ERR:-0}" = "1" ]; then
        _log_stderr "$_l"
      else
        _LOG_ERR=0
      fi
      ;;
    *)
      _LOG_ERR=0
      ;;
  esac
}

usage() {
  cat <<'USAGE'
DPanel 定时任务自动更新脚本

跑一轮更新就结束，触发频率交给 DPanel 的「计划任务」配置。
同一目标只挂一个计划任务即可（脚本内部不加锁，并发由 DPanel 保证）。

两条路各用各的长处：
  容器          → 交给 DPanel `container:upgrade`（先检查，确实有新版本才升级；
                  升级失败 DPanel 会自行回滚，并留下 <容器名>-bak-<时间戳> 备份容器）
  Compose 项目  → 用 `docker compose pull` + `docker compose up -d` 就地重新部署
                  （compose 自己知道这个项目有哪些容器、用哪个文件，不需要额外登记）
                  Compose 分支在部署成功后会顺手回收「本项目淘汰下来的、已无标签、
                  无容器引用的旧镜像」，整批删掉、不留回滚点；
                  容器分支不做回收（那边有 DPanel 的备份容器做回滚点）。

用法：
  container-autoupdate.sh --compose <项目名>     更新一个 Compose 项目
  container-autoupdate.sh --container <容器名>   更新一个普通容器
  container-autoupdate.sh --help                 显示本帮助

目标也可以写在文件顶部配置区（COMPOSE_NAME / CONTAINER_NAME），或用环境变量
UPD_COMPOSE / UPD_CONTAINER 指定。优先级：命令行 > 环境变量 > 配置区。
两种目标必须且只能指定一个。

选项：
  --compose <名>         Compose 项目名（项目目录/文件会自动从容器标签反查）
  --container <名>       容器名
  --compose-dir <路径>   Compose 项目目录；不给时自动反查，一般不用填
  --docker-sock <路径>   docker CLI 用的 socket；也可用 DOCKER_HOST
  --dpanel-container <名>   DPanel 容器名（默认 dpanel）；在容器内直接跑时用不到
  --dpanel-bin <路径>       DPanel CLI 在容器里的路径（默认 /app/server/dpanel）
  --dpanel-docker-env <名>  DPanel 里的 docker 环境名（默认 local）
  --dry-run              只检查不动手：容器模式问 DPanel，Compose 模式只列出涉及的镜像
  -h, --help             显示本帮助
  -V, --version          显示版本

环境变量：
  UPD_COMPOSE / UPD_CONTAINER   目标（同命令行）
  DOCKER_SOCK / DOCKER_HOST     docker CLI 的连接端点
  COMPOSE_DIR                   Compose 项目目录（同 --compose-dir）
  DPANEL_NAME                   DPanel 容器名（默认 dpanel）
  DPANEL_BIN                    DPanel CLI 路径（默认 /app/server/dpanel）
  DPANEL_DOCKER_ENV             DPanel 里的 docker 环境名（默认 local）
  DRY_RUN=1                     同 --dry-run
  T_HARD                        整轮时间硬上限（秒，默认 540）
  T_INSPECT / DP_T_CHECK        单次「检查」调用超时（秒，默认 120）
  DP_T_UPGRADE                  单次容器升级调用超时（秒，默认 420）
  DP_T_PULL / DP_T_UP           Compose 模式的 pull / up -d 超时（秒，默认 420 / 180）
  DP_MIN_UPGRADE                剩余预算低于这个值就不动手（秒，默认 90）

退出码：
  0  成功，或无需更新
  1  配置/环境错误，或本轮未能完成更新（目标保持原样）
  130  被 Ctrl-C（SIGINT）中断
  143  被 SIGTERM / SIGHUP 中断（计划任务执行超时常见）

示例：
  # DPanel 计划任务里跑（推荐）：把下面这条命令填进计划任务的「命令」，
  # 由 DPanel 按你设定的周期触发。
  container-autoupdate.sh --compose myapp

  # 先看一眼有没有新版本，不动手
  container-autoupdate.sh --container myapp --dry-run

  # Compose 项目的目录通常是自动认出来的；要显式指定也可以：
  container-autoupdate.sh --compose myapp --compose-dir /opt/myapp

  # 推荐：整段填进 DPanel 计划任务的「脚本」框
  #   SRC 里一行一个源，只写站点域名；镜像站那条会拼成「站点/原始 GitHub 地址」，
  #   https://github.com 那条是直连。按顺序试，第一个内容合格的才算成功。
  #   全部失败时沿用上一轮的副本，照样能跑，但会打一行 WARN 说明（不许静默）。
  G=https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh
  SRC='https://gh-proxy.com
  https://ghfast.top
  https://github.com'
  T=/tmp/ct-new.sh
  okfile() { [ -f "$1" ] || return 1; [ "$(wc -c <"$1")" -gt 1000 ] && sh -n "$1" 2>/dev/null && grep -q container-autoupdate "$1"; }
  for u in $SRC; do
    case "$u" in "https://github.com") url=$G ;; *) url="$u/$G" ;; esac
    curl -fsSL --max-time 30 "$url" -o "$T" 2>/dev/null || continue
    okfile "$T" && break
  done
  if okfile "$T"; then
    mv -f "$T" /tmp/container-autoupdate.sh
  else
    echo "WARN 三个源都没拿到可用的脚本，沿用上一轮的副本"
  fi
  [ -s /tmp/container-autoupdate.sh ] || { echo "ERR 拿不到可用的更新脚本，也没有上一轮的副本" >&2; exit 1; }
  sh /tmp/container-autoupdate.sh --compose myapp

  # 想锁死版本：把 G 里的 latest/download 换成带版本号的路径
  # releases/download/v4.0.1/container-autoupdate.sh

USAGE
}

parse_args() {
  # 记录「命令行上显式给过哪个目标」。不能只靠最终变量值判断，
  # 因为 --compose 与 --container 各自会清空对方，导致
  # `--compose a --container b` 变成「后者胜出」而静默通过——
  # 这与「两种目标必须且只能指定一个」的规则冲突，必须报错。
  _SAW_COMPOSE=0
  _SAW_CONTAINER=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --compose)      [ "$#" -ge 2 ] || { echo "ERR --compose 缺少参数" >&"$ERR_FD"; exit 1; }
                      COMPOSE_NAME="$2"; CONTAINER_NAME=""; _SAW_COMPOSE=1; shift 2 ;;
      --container)    [ "$#" -ge 2 ] || { echo "ERR --container 缺少参数" >&"$ERR_FD"; exit 1; }
                      CONTAINER_NAME="$2"; COMPOSE_NAME=""; _SAW_CONTAINER=1; shift 2 ;;
      --docker-sock)  [ "$#" -ge 2 ] || { echo "ERR --docker-sock 缺少参数" >&"$ERR_FD"; exit 1; }
                      DOCKER_SOCK="$2"; shift 2 ;;
      --compose-dir)  [ "$#" -ge 2 ] || { echo "ERR --compose-dir 缺少参数" >&"$ERR_FD"; exit 1; }
                      COMPOSE_DIR="$2"; shift 2 ;;
      --dpanel-container) [ "$#" -ge 2 ] || { echo "ERR --dpanel-container 缺少参数" >&"$ERR_FD"; exit 1; }
                      DPANEL_NAME="$2"; shift 2 ;;
      --dpanel-bin)   [ "$#" -ge 2 ] || { echo "ERR --dpanel-bin 缺少参数" >&"$ERR_FD"; exit 1; }
                      DPANEL_BIN="$2"; shift 2 ;;
      --dpanel-docker-env) [ "$#" -ge 2 ] || { echo "ERR --dpanel-docker-env 缺少参数" >&"$ERR_FD"; exit 1; }
                      DPANEL_DOCKER_ENV="$2"; shift 2 ;;
      --dry-run)      DRY_RUN=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      -V|--version)   echo "$VERSION"; exit 0 ;;
      *)              echo "ERR 未知参数：$1（用 --help 查看用法）" >&"$ERR_FD"; exit 1 ;;
    esac
  done
  # 命令行上两个目标都显式给过 → 直接拒绝，不做「后者胜出」的静默覆盖
  if [ "$_SAW_COMPOSE" = "1" ] && [ "$_SAW_CONTAINER" = "1" ]; then
    echo "ERR 配置错误：--compose 与 --container 必须且只能给一个" >&"$ERR_FD"
    exit 1
  fi
}

# ---------- 与 DPanel 打交道 ----------
# 两种运行方式，效果完全一样（同一个二进制、同一份 config、同一个 docker socket）：
#   1) 脚本本来就在 DPanel 容器里（计划任务的常见情形）→ 直接执行二进制；
#   2) 脚本在别的容器 / 宿主上 → docker exec 进 DPanel 容器执行。
# 判定必须在 parse_args 之后（见主流程）：--dpanel-bin 能改 $DPANEL_BIN，
# 在这里提前判会一直用默认路径做判断，走错分支。
DP_IN_CONTAINER=0

# 调用 DPanel CLI。$1 = 超时秒数，其余是子命令与参数。
# 不用 -q/--quiet：它会把结果 JSON 一起吞掉（DPanel 1.11.2 实测），
# 结果行必须自己从输出里挑（见 dp_json）。
dp_cli() {
  _dt="$1"; shift
  if [ "$DP_IN_CONTAINER" = "1" ]; then
    timeout -s KILL "$_dt" "$DPANEL_BIN" "$@" 2>&1
  else
    timeout -s KILL "$_dt" docker exec "$DPANEL_NAME" "$DPANEL_BIN" "$@" 2>&1
  fi
}

# DPanel CLI 会把 DEBUG / GORM SQL 日志一起写到 stdout，结果 JSON 是最后一个
# 以 { 开头的行（DEBUG 行以 [ 开头）。取不到就说明确实没有结果。
dp_json() { printf '%s\n' "$1" | sed -n '/^{/p' | tail -n1; }

# 出错时要能看到 DPanel 自己说的话：把非 DEBUG、非 JSON 的行挑出来。
dp_noise() { printf '%s\n' "$1" | grep -v '^\[' | grep -v '^{' | grep -v '^$' | tail -n3; }

# 从结果 JSON 里取一个简单字段（字符串、数字或 true/false）。
# 字符串值里**会有逗号**（DPanel 的错误文本就是），所以不能按逗号截断；
# 空字符串 "error":"" 必须返回空，否则会被当成「有错误」。
jp_val() {
  _v=$(printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | tail -n1)
  if [ -n "$_v" ] || printf '%s' "$1" | grep -q "\"$2\":\"\""; then
    printf '%s' "$_v"
    return 0
  fi
  printf '%s' "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p" | tail -n1 \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# DPanel 的失败一律体现在 JSON 里，不能看退出码：
# 容器不存在时 `container:upgrade` 会返回 rc=0 但 JSON 是 {"code":500,...}（实测）。
# 真机实测到的形状（DPanel 1.11.2）：
#   成功 —— 容器检查 {"upgrade":..,"status":"latest"|"upgrade"}；
#           容器升级 {"containerId":"..."} —— 两者都**没有 code 字段**；
#   失败 —— {"code":500,"error":"url: /dpanel/api/..."}。
# （历史：v2.0.0 时 Compose 也交给 DPanel，`compose:deploy` 对未登记的项目同样是
#   rc=0 + {"code":500,...}，成功形状是 {"name":"项目名"}、没有 code。规则一致。）
# 所以判定必须是「code >= 400 或 status=failed 或有 error 文本才算失败」，
# 绝不能写成「code 不等于 200 就是失败」——那会把没有 code 的成功当失败。
dp_failed() {
  _c=$(jp_val "$1" code)
  case "$_c" in
    ''|*[!0-9]*) ;;                                  # 没有 code / 不是数字：不是失败信号
    *) [ "$_c" -ge 400 ] && return 0 ;;
  esac
  [ "$(jp_val "$1" status)" = "failed" ] && return 0
  [ -n "$(jp_val "$1" error)" ] && return 0
  return 1
}

# 取出本次调用的可用超时：不超过该调用的期望值，也不超过剩余预算（至少 10 秒）。
# 内部超时必须显著小于计划任务的外部超时，否则被 SIGKILL 时日志里什么都留不下。
budget_timeout() {
  _want="$1"; _rest=$(left)
  [ "$_rest" -lt 10 ] && _rest=10
  [ "$_want" -gt "$_rest" ] && _want="$_rest"
  echo "$_want"
}
# DPanel 调用用的同一个预算函数（名字保留，读代码时更直观）
dp_timeout() { budget_timeout "$1"; }

check_deps() {
  _missing=""
  for _b in timeout sed awk grep; do
    command -v "$_b" >/dev/null 2>&1 || _missing="$_missing $_b"
  done
  # 什么时候需要 docker CLI：
  #   · Compose 分支要自己调 `docker compose`；
  #   · 容器分支在 DPanel 容器里跑时，用 `docker exec` 进 DPanel（所以也需要）；
  #     只有「本来就跑在 DPanel 容器里 + 容器分支」这一种情况用不到 docker。
  _need_docker=0
  if [ "$_GOAL" = "compose" ] || [ "$DP_IN_CONTAINER" != "1" ]; then
    _need_docker=1
    command -v docker >/dev/null 2>&1 || _missing="$_missing docker"
  fi
  if [ -n "$_missing" ]; then
    echo "ERR 缺少依赖命令：$_missing" >&"$ERR_FD"
    echo "    需要 timeout 与 busybox 或 coreutils 基础工具；" >&"$ERR_FD"
    echo "    Compose 模式还需要 docker（含 docker compose 插件）；不在 DPanel 容器里跑时也需要 docker" >&"$ERR_FD"
    exit 1
  fi
  if [ "$_need_docker" = "1" ]; then
    # 要用 docker 就先验证它真的连得上：连不上时报「找不到 DPanel CLI」
    # 会把人引到完全无关的排查方向（AGENTS.md 记过这个坑）。
    if ! timeout -s KILL 20 docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      echo "ERR 无法连接 Docker（DOCKER_HOST=${DOCKER_HOST:-未设置}）" >&"$ERR_FD"
      echo "    请确认 Docker 正在运行，且当前用户有权限访问 socket" >&"$ERR_FD"
      exit 1
    fi
  fi
  if [ "$_GOAL" = "compose" ]; then
    # Compose 分支的更新动作全靠 compose 插件，它不可用就没必要继续。
    if ! timeout -s KILL 20 docker compose version >/dev/null 2>&1; then
      echo "ERR 无法执行 docker compose（缺 compose 插件？）" >&"$ERR_FD"
      echo "    Compose 模式需要 Docker Compose v2 插件版（docker compose，不是 docker-compose）" >&"$ERR_FD"
      exit 1
    fi
    return 0
  fi
  # 还没指定目标时不必检查 DPanel：下面的主流程会直接报「必须且只能指定一个目标」，
  # 那才是用户真正要处理的问题。
  [ -z "$_GOAL" ] && return 0
  # 容器分支：DPanel CLI 必须可用，所有更新动作都靠它。
  _dv=$(dp_cli "$(dp_timeout "$DP_T_CHECK")" version | sed -n 's/^version: *//p' | head -n1)
  if [ -z "$_dv" ]; then
    echo "ERR 无法调用 DPanel CLI（$DPANEL_BIN）" >&"$ERR_FD"
    if [ "$DP_IN_CONTAINER" = "1" ]; then
      echo "    脚本当前环境里没有这个可执行文件" >&"$ERR_FD"
    else
      echo "    已尝试：docker exec $DPANEL_NAME $DPANEL_BIN version" >&"$ERR_FD"
      echo "    DPanel 容器名不是 $DPANEL_NAME 时用 --dpanel-container 指定，路径不同用 --dpanel-bin" >&"$ERR_FD"
    fi
    exit 1
  fi
  if [ "$DP_IN_CONTAINER" = "1" ]; then
    log "DPanel CLI 就绪（version $_dv，直接执行）"
  else
    log "DPanel CLI 就绪（version $_dv，docker exec $DPANEL_NAME）"
  fi
}

# ---------- 容器模式：交给 DPanel container:upgrade ----------
container_update() {
  log "MODE container 容器=$CONTAINER_NAME"
  _out=$(dp_cli "$(dp_timeout "$DP_T_CHECK")" container:upgrade --name "$CONTAINER_NAME" --docker-env "$DPANEL_DOCKER_ENV")
  _j=$(dp_json "$_out")
  if [ -z "$_j" ]; then
    log "ERR DPanel 没有返回可解析的结果（container:upgrade --name $CONTAINER_NAME）"
    dp_noise "$_out" | while IFS= read -r _nl; do log "    $_nl"; done
    log "    容器未做任何改动"
    EXIT_CODE=1
    return 1
  fi
  if dp_failed "$_j"; then
    log "ERR DPanel 检查失败：$(jp_val "$_j" error)"
    dp_noise "$_out" | while IFS= read -r _nl; do log "    $_nl"; done
    log "    容器未做任何改动"
    EXIT_CODE=1
    return 1
  fi
  if [ "$(jp_val "$_j" upgrade)" != "true" ]; then
    log "OK 容器 $CONTAINER_NAME 已是最新（DPanel 报告 status=$(jp_val "$_j" status)）"
    return 0
  fi
  log "发现新版本（远端 digest=$(jp_val "$_j" digest)）"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY 只检查不动手，本轮不升级"
    return 0
  fi
  _rest=$(left)
  if [ "$_rest" -lt "$DP_MIN_UPGRADE" ]; then
    # 先判失败再打 WARN：log() 靠 EXIT_CODE 决定这句要不要进真 stderr（见文件头部说明）
    EXIT_CODE=1
    log "WARN 剩余时间不足（${_rest}s < ${DP_MIN_UPGRADE}s），本轮不启动升级，容器保持原样"
    log "     下一轮计划任务会重新检查；也可以把 T_HARD 或计划任务的超时调大"
    return 1
  fi
  _t=$(dp_timeout "$DP_T_UPGRADE")
  log "交给 DPanel 升级（等待上限 ${_t}s；新容器起不来时 DPanel 会自行回滚）"
  _out2=$(dp_cli "$_t" container:upgrade --name "$CONTAINER_NAME" --upgrade --docker-env "$DPANEL_DOCKER_ENV")
  _j2=$(dp_json "$_out2")
  if [ -z "$_j2" ]; then
    log "ERR DPanel 升级没有返回可解析的结果（可能等待超时，或 DPanel 侧出错）"
    dp_noise "$_out2" | while IFS= read -r _nl; do log "    $_nl"; done
    log "    容器保持原样；DPanel 若已重建过会自行回滚（备份容器 <容器名>-bak-<时间戳>）"
    EXIT_CODE=1
    return 1
  fi
  if dp_failed "$_j2"; then
    log "ERR DPanel 升级失败：$(jp_val "$_j2" error)"
    dp_noise "$_out2" | while IFS= read -r _nl; do log "    $_nl"; done
    log "    容器保持原样；DPanel 若已重建过会自行回滚（备份容器 <容器名>-bak-<时间戳>）"
    EXIT_CODE=1
    return 1
  fi
  log "OK DPanel 已完成升级（containerId=$(jp_val "$_j2" containerId)）"
  return 0
}

# ---------- Compose 模式：用 docker compose 自己就地重新部署 ----------
# compose 自己就把「这个项目有哪些容器、用哪个 compose 文件、工作目录在哪」
# 记在容器的标签上（com.docker.compose.project.*），所以既不需要用户配置目录，
# 也不需要项目先在别处登记。这一支只做三件事：
#   认清项目 → `docker compose pull` → `docker compose up -d`，
# 然后把「哪些容器换了镜像」「有没有容器起不来」如实报出来。
#
# 安全原则：只用 compose 自己的 pull / up -d；不手工 tag、不手工 create、
# 不加 --remove-orphans（它会删掉不在当前 compose 文件里的容器，属于数据事故）。

# compose 调用的环境：参数一律走环境变量，不拼进命令行。
# （路径含空格时 compose 会打印 Usage 却返回 rc=0 —— 静默出错，AGENTS.md 有记载。）
compose_env() {
  COMPOSE_PROJECT_NAME="$COMPOSE_NAME"
  export COMPOSE_PROJECT_NAME
  if [ -n "$C_FILE" ]; then
    COMPOSE_FILE="$C_FILE"
    COMPOSE_PATH_SEPARATOR=":"
    export COMPOSE_FILE COMPOSE_PATH_SEPARATOR
  fi
  if [ -n "$C_ENVF" ]; then
    COMPOSE_ENV_FILES="$C_ENVF"
    export COMPOSE_ENV_FILES
  fi
}

# 在项目目录里跑 compose。工作目录必须对：compose 文件里的相对路径靠它解析。
# 退出码 99 = 进不去目录（与 compose 自己的退出码区分开）。
# stderr 合并进 stdout：失败时要把 compose 说的话一起报出来。
compose_run() {
  _t="$1"; shift
  ( cd "$C_DIR" 2>/dev/null || exit 99
    compose_env
    timeout -s KILL "$_t" docker compose "$@" 2>&1 )
}

# 只要 stdout（stderr 丢掉）：给 `config --images` 这种要解析输出的调用用，
# 免得 compose 的告警混进要解析的内容里。
compose_out() {
  _t="$1"; shift
  ( cd "$C_DIR" 2>/dev/null || exit 99
    compose_env
    timeout -s KILL "$_t" docker compose "$@" 2>/dev/null )
}

# 镜像 id 取短一点，日志里好读。
# 先把首尾空白剪掉再截断：传进来的可能是「 2754f35171f5」这种带前导空格的列表元素，
# 不剪的话 substr 会把空格也算进去，印出来的短 id 少一位（实测踩到过）。
_short_id() {
  printf '%s' "$1" | sed 's/^sha256://' \
    | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print substr($0, 1, 12) }'
}

# 认清这个项目：工作目录 + compose 文件 + env 文件。
# 优先用 compose 自己写在容器上的标签（那是最准的：就是当初用的那个文件），
# 标签查不到时才用 --compose-dir / COMPOSE_DIR 兜底（那种情况让 compose 在
# 该目录里自己找 compose.yaml / docker-compose.yml）。
compose_locate() {
  C_DIR=""; C_FILE=""; C_ENVF=""
  _cid=$(docker ps -a --filter "label=com.docker.compose.project=$COMPOSE_NAME" \
           --format '{{.ID}}' 2>/dev/null | head -n1)
  if [ -n "$_cid" ]; then
    _wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$_cid" 2>/dev/null)
    _cf=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$_cid" 2>/dev/null)
    _ef=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.environment_file"}}' "$_cid" 2>/dev/null)
    [ -n "$_wd" ] && C_DIR="$_wd"
    [ -n "$_cf" ] && C_FILE="$_cf"
    [ -n "$_ef" ] && C_ENVF="$_ef"
  fi
  if [ -z "$C_DIR" ] && [ -n "$COMPOSE_DIR" ]; then
    C_DIR="$COMPOSE_DIR"
  fi
  if [ -z "$C_DIR" ]; then
    log "ERR 找不到 Compose 项目 $COMPOSE_NAME 的项目目录"
    log "    当前 Docker 里没有带「$COMPOSE_NAME」这个 compose 项目标签的容器，反查不到"
    log "    处理方式二选一："
    log "      1) 用 --compose-dir <路径> 指定 compose 文件所在目录"
    log "      2) 确认项目名写法；项目还没部署过就先手动 compose up 一次"
    return 1
  fi
  if [ ! -d "$C_DIR" ]; then
    log "ERR Compose 项目目录不存在：$C_DIR"
    return 1
  fi
  return 0
}

# 本项目所有容器（含已停止的）
compose_cids() {
  docker ps -a --filter "label=com.docker.compose.project=$COMPOSE_NAME" \
    --format '{{.ID}}' 2>/dev/null
}

# 「容器名 → 镜像 id」快照，用来对比哪些容器换了镜像。
# 必须用**容器名**当键：`docker compose up -d` 重建容器后 ID 会变，
# 用 ID 当键的话，每个被重建的容器在「部署后」里都是新 ID，
# 于是全被误判成「新建」，永远报不出「已重建」（N1 真机实测踩到）。
compose_snapshot() {
  compose_cids | while IFS= read -r _id; do
    [ -n "$_id" ] || continue
    _nm=$(docker inspect -f '{{.Name}}' "$_id" 2>/dev/null | sed 's|^/||')
    [ -n "$_nm" ] || continue
    echo "$_nm $(docker inspect -f '{{.Image}}' "$_id" 2>/dev/null)"
  done
}

# 运行状态统计：输出「运行中的数量 总数」
compose_running_stat() {
  _tot=0; _run=0
  for _id in $(compose_cids); do
    _tot=$(( _tot + 1 ))
    case "$(docker inspect -f '{{.State.Running}}' "$_id" 2>/dev/null)" in
      true) _run=$(( _run + 1 )) ;;
    esac
  done
  echo "$_run $_tot"
}

# ---------- 旧镜像回收（只用于 Compose 分支）----------
# 从形如 `registry:5000/a/b:tag`、`a/b`、`a/b@sha256:...` 的引用里取出仓库名。
# 冒号只有在最后一个斜杠之后才算标签分隔符 —— 前面的冒号是 registry 端口。
_img_repo() {
  printf '%s' "$1" | sed 's/@.*$//' | awk '{
    n = split($0, a, "/"); last = a[n]
    if (index(last, ":") > 0) sub(/:[^:]*$/, "", $0)
    print
  }'
}

# 回收本项目本轮淘汰下来的旧镜像。
#   $1 = 本项目涉及的镜像引用（多行，来自 `docker compose config --images`）
#
# 只删同时满足这三条的镜像，缺一条都不动：
#   1) 属于本项目：镜像的 RepoDigests 能对上本项目的镜像仓库。`RepoDigests` 形如
#      `仓库@sha256:...`，标签被搬走之后它仍然在 —— 这正是能认出「已变 <none> 的旧镜像」
#      的唯一依据（N-2 变成 <none> 后 `Repository` 字段是 `<none>`，不是仓库名，
#      按标签前缀匹配永远看不到它）。**不许**用「凡是 <none> 就删」这种宽判据：
#      别的 compose 项目、用户自己 build 的东西都可能挂在同一台机器上。
#      本地 build / import 出来的镜像没有 RepoDigests，认不出归属，一律留着不动。
#   2) 不带任何 tag（`<none>:<none>`）：还有标签说明它是当前版本，或是用户自己
#      打的 `<仓库>:prev` / `:bad` / `:rollback-pending`，那三种一律不能碰。
#   3) 没有任何容器引用（含已停止的、含 DPanel 的 `<容器名>-bak-<时间戳>` 备份容器）。
#      删除用不带 -f 的 `docker rmi`，真有引用时它自己会拒绝，这是最后一道保险。
#
# v5.0.0 起**不再保留回滚点**：`up -d` 成功之后，本轮淘汰下来的旧镜像全部回收。
# v4.1.0 曾保留「更新前在用的那个」当回滚点，但那样稳态下每个 Compose 项目永远
# 躺着一个 <none>，与「别堆积」的目标自相矛盾。代价是 Compose 模式不能再靠
# `docker tag <旧镜像ID>` 回退 —— 要回退只能把 compose 文件里的 tag 钉回旧版本再跑一轮。
compose_reclaim() {
  _imgs="$1"
  _rec=0
  [ "$DRY_RUN" = "1" ] && return 0

  # 本项目的仓库名清单。读不出来（`config` 失败等）就什么都不删，宁可留着。
  _repos=$(printf '%s\n' "$_imgs" | while IFS= read -r _x; do
    [ -n "$_x" ] && _img_repo "$_x"
  done | awk 'NF' | sort -u)
  [ -n "$_repos" ] || return 0

  # 挑出「本项目的、无标签的、无引用的」镜像。
  # 比对一律走 _short_id 归一化：`docker images -q` 给的是 12 位短 id，而容器
  # inspect 出来的 `.Image` 是 `sha256:<64位>`，两种写法不能直接比字符串。
  _cands=""
  for _id in $(docker images -a --filter dangling=true -q 2>/dev/null | sort -u); do
    [ -n "$_id" ] || continue
    _sid=$(_short_id "$_id")
    [ -n "$_sid" ] || continue
    # 条件 2：确认真的一个标签都没有（`dangling=true` 的语义在不同 docker 版本上
    # 有出入，这里实测一遍，不能只信 filter）
    _tags=$(docker image inspect -f '{{range .RepoTags}}{{println .}}{{end}}' "$_id" 2>/dev/null | awk 'NF')
    [ -z "$_tags" ] || continue
    # 条件 1：归属 —— 只认 RepoDigests
    _mine=0
    for _r in $(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$_id" 2>/dev/null | awk 'NF'); do
      if printf '%s\n' "$_repos" | grep -Fxq "$(_img_repo "$_r")"; then _mine=1; break; fi
    done
    [ "$_mine" = "1" ] || continue
    # 条件 3：没有容器引用
    [ -n "$(docker ps -a -q --filter ancestor="$_id" 2>/dev/null)" ] && continue
    _cands="$_cands $_sid"
  done
  [ -n "$_cands" ] || return 0

  for _id in $_cands; do
    docker rmi "$_id" >/dev/null 2>&1 && _rec=$(( _rec + 1 ))
  done

  [ "$_rec" -gt 0 ] && log "    回收旧镜像 $_rec 个（已无标签、无容器引用，本项目归属）"
  return 0
}

compose_update() {
  log "MODE compose 项目=$COMPOSE_NAME"
  compose_locate || { EXIT_CODE=1; return 1; }

  _raw=$(compose_out "$(budget_timeout "$DP_T_CHECK")" config --images)
  _irc=$?
  _imgs=$(printf '%s\n' "$_raw" | awk 'NF && !seen[$0]++')
  log "    目录=$C_DIR"
  [ -n "$C_FILE" ] && log "    文件=$C_FILE"
  if [ "$_irc" -ne 0 ]; then
    log "WARN docker compose config 没能读出这个项目的镜像清单（退出码 $_irc），继续按流程走"
  fi
  if [ -n "$_imgs" ]; then
    printf '%s\n' "$_imgs" | while IFS= read -r _i; do
      [ -n "$_i" ] && log "    镜像: $_i"
    done
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY 只检查不动手：上面是这个项目涉及的镜像，本轮不拉取、不部署"
    log "    要真正更新就去掉 --dry-run（拉取本身就是「有没有新版本」的判断）"
    return 0
  fi

  _rest=$(left)
  if [ "$_rest" -lt "$DP_MIN_UPGRADE" ]; then
    # 先判失败再打 WARN：log() 靠 EXIT_CODE 决定这句要不要进真 stderr（见文件头部说明）
    EXIT_CODE=1
    log "WARN 剩余时间不足（${_rest}s < ${DP_MIN_UPGRADE}s），本轮不部署，项目保持原样"
    return 1
  fi

  _before=$(compose_snapshot)

  # 1) 拉取。这一步同时也是「有没有新版本」的判断：没有新版时它是很快的空操作。
  _t=$(budget_timeout "$DP_T_PULL")
  log "拉取镜像（docker compose pull，等待上限 ${_t}s）"
  _out=$(compose_run "$_t" pull)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    if [ "$_rc" = "99" ]; then
      log "ERR 无法进入 Compose 项目目录：$C_DIR"
    else
      log "ERR 拉取失败（docker compose pull 退出码 $_rc），本轮不部署，项目保持原样"
      printf '%s\n' "$_out" | tail -n5 | while IFS= read -r _nl; do log "    $_nl"; done
    fi
    EXIT_CODE=1
    return 1
  fi

  # 2) 就地重新部署。不加 --remove-orphans：它会删掉不在当前 compose 文件里的容器。
  _t=$(budget_timeout "$DP_T_UP")
  log "就地重新部署（docker compose up -d，等待上限 ${_t}s）"
  _out=$(compose_run "$_t" up -d)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    log "ERR 重新部署失败（docker compose up -d 退出码 $_rc）"
    printf '%s\n' "$_out" | tail -n5 | while IFS= read -r _nl; do log "    $_nl"; done
    log "    compose 文件与容器定义都没被脚本改过，可以直接再跑一轮"
    EXIT_CODE=1
    return 1
  fi

  # 3) 如实报告：哪些容器换了镜像、哪些是这一轮新建的、有没有容器起不来。
  # 按**容器名**比对（见 compose_snapshot 的注释：重建后容器 ID 会变，用 ID 当键会把重建误判成新建）。
  # 循环直接用 compose_cids 的 ID 列表，不放进管道里 —— 管道会开子 shell，计数器就丢了。
  _changed=0
  _new=0
  for _id in $(compose_cids); do
    _nm=$(docker inspect -f '{{.Name}}' "$_id" 2>/dev/null | sed 's|^/||')
    [ -n "$_nm" ] || continue
    _a=$(docker inspect -f '{{.Image}}' "$_id" 2>/dev/null)
    _b=$(printf '%s\n' "$_before" | awk -v n="$_nm" '$1==n{print $2; exit}')
    if [ -n "$_a" ] && [ -z "$_b" ]; then
      # 部署前没有这个容器：它是这一轮新建的（首次部署，或 compose 文件里新加的服务）。
      _new=$(( _new + 1 ))
      log "    新建：$_nm（$(_short_id "$_a")）"
    elif [ -n "$_b" ] && [ -n "$_a" ] && [ "$_b" != "$_a" ]; then
      _changed=$(( _changed + 1 ))
      log "    已重建：$_nm（$(_short_id "$_b") → $(_short_id "$_a")）"
    fi
  done

  _stat=$(compose_running_stat)
  _run=${_stat%% *}; _tot=${_stat##* }

  # 汇总要如实：换了镜像 / 新建 / 真的什么都没变，是三件不同的事，不能混成一句话。
  if [ "$_changed" -gt 0 ] && [ "$_new" -gt 0 ]; then
    log "OK Compose 项目 $COMPOSE_NAME 已重新部署（$_changed/$_tot 个容器换了镜像，$_new 个新建）"
  elif [ "$_changed" -gt 0 ]; then
    log "OK Compose 项目 $COMPOSE_NAME 已重新部署（$_changed/$_tot 个容器换了镜像）"
  elif [ "$_new" -gt 0 ]; then
    log "OK Compose 项目 $COMPOSE_NAME 已部署（$_new 个容器新建）"
  else
    log "OK Compose 项目 $COMPOSE_NAME 已是最新（拉取后没有容器需要重建）"
  fi

  if [ "$_tot" -gt 0 ] && [ "$_run" != "$_tot" ]; then
    log "ERR 有容器没在运行（$_run/$_tot running）："
    for _id in $(compose_cids); do
      _st=$(docker inspect -f '{{.State.Status}}' "$_id" 2>/dev/null)
      [ "$_st" = "running" ] || log "    $(docker inspect -f '{{.Name}}' "$_id" 2>/dev/null | sed 's|^/||') $_st"
    done
    log "    compose 文件没被改过；用 docker compose logs <服务名> 看具体原因"
    EXIT_CODE=1
    return 1
  fi

  # 4) 回收本项目这一轮淘汰下来的旧镜像（pull 把标签搬走后它们变成 <none>，没有这一步就会一直沉淀）。
  # 只在项目健康时做：部署没成功的话，旧镜像可能还是当前在用的那份，不能动。
  # 预算不足就跳过 —— 回收只是省磁盘，不值得为它冒被 SIGKILL 的风险（那时计划任务里什么都看不到）。
  if [ "$(left)" -ge 20 ]; then
    compose_reclaim "$_imgs"
  else
    log "    剩余时间不足，跳过旧镜像回收（不影响本次部署结果）"
  fi

  log "    运行状态：$_run/$_tot"
  return 0
}

# ---------- 主流程 ----------
parse_args "$@"

# 判定「是不是就在 DPanel 容器里」：必须在 parse_args 之后，
# 否则 --dpanel-bin 指定的路径不参与判断（DPanel 会自动探测它的存在）。
[ -x "$DPANEL_BIN" ] && DP_IN_CONTAINER=1

# --docker-sock 仍然认：以前它是给 docker API 用的，现在只用来指定 docker CLI 的端点。
if [ -n "$DOCKER_SOCK" ]; then
  export DOCKER_HOST="unix://$DOCKER_SOCK"
fi

# 每次真实运行都在日志里留一行版本号：排查历史问题时，能立刻看出那一轮
# 跑的是哪一版脚本（升级过 latest 之后尤其重要）。
log "container-autoupdate v$VERSION 启动"

# 目标判定（依赖检查与后面的分支都要用）
_GOAL=""
if [ -n "$COMPOSE_NAME" ] && [ -z "$CONTAINER_NAME" ]; then
  _GOAL="compose"
elif [ -z "$COMPOSE_NAME" ] && [ -n "$CONTAINER_NAME" ]; then
  _GOAL="container"
fi

check_deps

case "$_GOAL" in
  compose)   compose_update ;;
  container) container_update ;;
  *)
    log "ERR 必须且只能指定一个目标：--compose <项目名> 或 --container <容器名>"
    log "    也可以用环境变量 UPD_COMPOSE / UPD_CONTAINER，或改文件顶部配置区"
    EXIT_CODE=1
    ;;
esac

log "本轮结束，总耗时 $(elapsed)s"
exit "$EXIT_CODE"
