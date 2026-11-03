#!/bin/sh
# ===========================================================================
# DPanel 定时任务自动更新脚本 —— 一轮更新逻辑，交给 DPanel 的「计划任务」
# 按固定周期触发。脚本本身不含更新频率逻辑：频率、启停、并发全归 DPanel 管。
# 手动运行也允许，但那是「跑一轮就结束」的单次更新，不建议再套 cron / systemd timer。
# 当前版本见 VERSION 字段，用 --version 查看。
#
# 目标二选一：一个 Compose 项目名，或一个容器名。可以用命令行参数、
# 环境变量或文件顶部配置区指定，三者等价，优先级：命令行 > 环境变量 > 配置区。
# 镜像引用从 Compose 文件 / 容器本身自动发现，不需要手工填镜像地址。
#
# 安全原则：
#   · Compose：显式 -p 固定项目，保留 config/env 文件；不使用 --remove-orphans；
#     up 失败后真正回滚，回滚失败绝不报成功。
#   · 容器：不把运行态 NetworkSettings 整包回投；按声明式字段重建网络；
#     实际挂载（含匿名卷真实名称）转成显式 Mounts，避免重复挂载和换卷；
#     创建后、启动前先做完整规格校验；按容器 ID 操作，失败可恢复。
#   · AutoRemove、container:* 网络及其依赖、VolumesFrom、非常规挂载/网络、
#     Compose 管理的容器等不能安全处理的形态，跳过并说明原因。
#   · 拉取只 kill 本轮 curl PID（curl 自带 --max-time，不会活得比脚本久）；
#     并发由 DPanel 计划任务保证（同一目标不要同时挂两个计划任务）；
#     坏版本按钉住时间计算 TTL。
#
# 注意：容器回滚只能恢复容器与镜像，不能撤销新程序已经做过的数据迁移。
# 生产数据库仍应另有备份。私有仓库需要匿名 API 拉取可用，否则安全中止。
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

COMPOSE_BASE="${COMPOSE_BASE:-}"   # Compose 目录回退路径；留空则只用容器 label 发现
COMPOSE_DIR="${COMPOSE_DIR:-}"     # 显式指定 Compose 项目目录（--compose-dir）
DOCKER_SOCK="${DOCKER_SOCK:-}"     # 显式指定 Docker socket；留空则用 DOCKER_HOST 或默认
SOCK=""
API_HOST="http://localhost"
API="http://localhost/v1.47"
STATE_ROOT="${STATE_ROOT:-/tmp/.container-autoupdate}"
BAD_TTL_DAYS="${BAD_TTL_DAYS:-7}"
COMPAT_UNTIL="${COMPAT_UNTIL:-}"   # --compat：用户声明「我只验证到这个版本」
PULL_RETRIES="${PULL_RETRIES:-1}"  # 拉取失败后的重试次数（0 = 不重试）

START=$(date +%s)
VERSION="1.1.2"
T_HARD="${T_HARD:-540}"
T_INSPECT="${T_INSPECT:-30}"
T_STALL="${T_STALL:-60}"
T_PULL_MAX="${T_PULL_MAX:-300}"
T_UP="${T_UP:-60}"
T_HEALTH="${T_HEALTH:-120}"
HEALTH_TRIES="${HEALTH_TRIES:-0}"
T_ROLLBACK="${T_ROLLBACK:-60}"
PLAIN_BOOT="${PLAIN_BOOT:-30}"
DRY_RUN="${DRY_RUN:-0}"
EXIT_CODE=0
ACTIVE_KIND=""
PULL_DIGEST=""
PULL_MSG=""
PULL_KIND=""      # 拉取失败的分类：ok / transient / permanent / stall / cap

now()     { date +%s; }
elapsed() { echo $(( $(now) - START )); }
left()    { echo $(( T_HARD - $(elapsed) )); }
# ---- 错误原因同时落到真正的 stderr ----
# 计划任务（DPanel）在任务失败时只保留 stderr、丢掉 stdout。
# 所以失败原因不能只写在 stdout 上，否则计划任务里只剩一句「exit status 1」。
# 判定规则：消息以 ERR / CRITICAL 开头的算「错误行」；紧随错误行之后的缩进补充行
# （log "   ..."）属于同一个错误块，一起进 stderr。
# 用 _LOG_ERR 记住「上一个错误块是否还在延续」，不靠猜缩进。
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
safe_key() { printf '%s' "$1" | sed 's|[^A-Za-z0-9_.-]|_|g'; }
json_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's|\\|\\\\|g; s|"|\\"|g')"; }

# ==================== 破坏性变更登记表 =====================================
# 为什么需要这张表：README 推荐的下载地址是 releases/latest/download/…，用户
# 粘贴一次就长期生效。上游发新版会直接作用到用户机器上。如果新版引入了破坏性
# 变更，脚本必须自己识别「你的调用方式还是旧写法」，并在输出里给出可执行的
# 迁移说明——而不是静默忽略旧参数，或抛出一句看不懂的错误。
#
# 每行用 | 分隔，空行与 # 开头的行忽略：
#     版本 | 类别 | 旧写法 | 新写法 | 说明
#
# 类别：
#   flag      命令行参数被移除/改名 → 用户传了它就立即中止并给出新写法
#   env       环境变量被移除/改名   → 该变量仍被设置就立即中止并给出新写法
#   behavior  默认行为或语义变化    → 无法从输入判断，靠「跨版本提示」与
#                                     --compat 声明来兜住
#
# 登记原则：只登记「会让用户已有的调用方式失效」的变更。
# 新增参数、改日志措辞、改内部实现都不要登记，否则每次发版都在打扰用户。
#
# 示例（真的出现变更时照这个样子加一行，把版本号换成实际版本）：
#   1.0.0|flag|--target|--compose / --container|1.0.0 起把 --target 拆成两个参数
#   1.0.0|env|UPD_TARGET|UPD_COMPOSE / UPD_CONTAINER|1.0.0 起把 UPD_TARGET 拆成两个变量
#   1.0.0|behavior|默认只保留 1 份回滚副本|--keep <份数>|1.0.0 起默认保留 2 份
BREAKING_TABLE='
1.0.0|env|LOCK_PREFIX|删除这个环境变量|1.0.0 起脚本不再使用互斥锁，并发由 DPanel 计划任务保证
1.0.0|behavior|同一更新目标由脚本内的互斥锁串行|同一目标只挂一个 DPanel 计划任务|1.0.0 起移除脚本内的互斥锁：v0.4.0 的锁会被残留的子进程长期占住，导致之后每一轮都跳过
'
# ==================== 登记表结束 ===========================================

# 版本比较：A > B 返回 0，否则返回 1。只比较前 3 段数字，缺的段按 0 处理。
ver_gt() {
  _a="$1"; _b="$2"; _i=1
  while [ "$_i" -le 3 ]; do
    _x=$(printf '%s' "$_a" | cut -d. -f"$_i"); _x=${_x:-0}
    _y=$(printf '%s' "$_b" | cut -d. -f"$_i"); _y=${_y:-0}
    case "$_x" in ''|*[!0-9]*) _x=0 ;; esac
    case "$_y" in ''|*[!0-9]*) _y=0 ;; esac
    [ "$_x" -gt "$_y" ] && return 0
    [ "$_x" -lt "$_y" ] && return 1
    _i=$(( _i + 1 ))
  done
  return 1
}

# A >= B
ver_ge() { ver_gt "$2" "$1" && return 1; return 0; }

# 取登记表里某一类别的行，输出「版本|旧写法|新写法|说明」
compat_rows() {
  printf '%s\n' "$BREAKING_TABLE" | while IFS='|' read -r _v _k _t _n _d; do
    case "$_v" in ''|'#'*) continue ;; esac
    [ "$_k" = "$1" ] || continue
    printf '%s|%s|%s|%s\n' "$_v" "$_t" "$_n" "$_d"
  done
}

# 用户传了一个已被移除的参数：立刻中止，给出新写法与迁移方式。
# 返回 0 表示「这是登记过的旧参数，已经报错退出」；返回 1 表示不认识的参数。
compat_removed_flag() {
  _rows=$(compat_rows flag)
  [ -n "$_rows" ] || return 1
  while IFS='|' read -r _v _t _n _d; do
    [ -n "$_v" ] || continue
    [ "$_t" = "$1" ] || continue
    log "ERR 这个参数已经不能用了：$1"
    log "    从 v$_v 起改为：$_n"
    log "    原因：$_d"
    log "    迁移方式：把 $1 换成 $_n"
    log "    或者把下载地址固定到旧版本（见 README「版本与升级」）"
    log "    本次未做任何改动，退出码 3"
    exit 3
  done <<EOF
$_rows
EOF
  return 1
}

# 已被移除的环境变量仍被设置：同样中止并给出新写法。
compat_removed_env() {
  _rows=$(compat_rows env)
  [ -n "$_rows" ] || return 0
  while IFS='|' read -r _v _t _n _d; do
    [ -n "$_v" ] || continue
    eval "_cur=\${$_t:-}"
    [ -n "$_cur" ] || continue
    # 「删除这个环境变量」是一个特殊的新写法：表示没有替代写法。
    # 这时不要打印「改为 X / 改用 X」那种绕口的句子。
    if [ "$_n" = "删除这个环境变量" ]; then
      log "ERR 这个环境变量已经不能用了：$_t（当前值=$_cur）"
      log "    从 v$_v 起：$_t 已移除"
      log "    原因：$_d"
      log "    迁移方式：删掉 $_t 即可，不需要任何替代设置"
    else
      log "ERR 这个环境变量已经不能用了：$_t（当前值=$_cur）"
      log "    从 v$_v 起改为：$_n"
      log "    原因：$_d"
      log "    迁移方式：删掉 $_t，改用 $_n"
    fi
    log "    或者把下载地址固定到旧版本（见 README「版本与升级」）"
    log "    本次未做任何改动，退出码 3"
    exit 3
  done <<EOF
$_rows
EOF
  return 0
}

# --compat <版本>：用户声明「我只验证到这个版本」。
# 若当前脚本含有比声明版本更新的 behavior 级破坏性变更，就硬停并说明原因。
compat_gate() {
  # 只有「显式给了 --compat 且给了非空值」才校验；--compat "" 是错误用法，不能静默放行。
  if [ "${_SAW_COMPAT:-0}" = "1" ] && [ -z "${COMPAT_UNTIL:-}" ]; then
    log "ERR --compat 的值不能为空（应形如 0.1.0）"
    log "    本次未做任何改动，退出码 3"
    exit 3
  fi
  [ -n "${COMPAT_UNTIL:-}" ] || return 0
  case "$COMPAT_UNTIL" in
    ''|*[!0-9.]*)
      log "ERR --compat 的值不合法：$COMPAT_UNTIL（应形如 0.1.0）"
      log "    本次未做任何改动，退出码 3"
      exit 3 ;;
  esac
  # 形态必须严格是「数字.数字.数字」：`1..2`、`1.2.` 这类会被 ver_gt 当成 0，悄悄放行。
  case "$COMPAT_UNTIL" in
    [0-9]*.[0-9]*.[0-9]*)
      case "$COMPAT_UNTIL" in
        *..*|*..|.*|*.*.*.*)
          log "ERR --compat 的值不合法：$COMPAT_UNTIL（应形如 0.1.0）"
          log "    本次未做任何改动，退出码 3"
          exit 3 ;;
      esac ;;
    *)
      log "ERR --compat 的值不合法：$COMPAT_UNTIL（应形如 0.1.0）"
      log "    本次未做任何改动，退出码 3"
      exit 3 ;;
  esac
  if ver_gt "$COMPAT_UNTIL" "$VERSION"; then
    log "ERR 声明的兼容版本($COMPAT_UNTIL)比当前脚本($VERSION)还新"
    log "    这通常意味着你在降级。请确认下载地址里的版本号，或去掉 --compat"
    log "    本次未做任何改动，退出码 3"
    exit 3
  fi
  _rows=$(compat_rows behavior)
  [ -n "$_rows" ] || return 0
  while IFS='|' read -r _v _t _n _d; do
    [ -n "$_v" ] || continue
    ver_gt "$_v" "$COMPAT_UNTIL" || continue    # 变更版本 <= 声明版本：用户已验证过，放行
    ver_ge "$VERSION" "$_v" || continue         # 当前脚本还没到该版本：不适用
    log "ERR 版本不兼容：当前脚本 $VERSION 含有影响你的破坏性变更"
    log "    从 v$_v 起：$_d"
    log "    应对：$_n"
    log "    你声明兼容到 $COMPAT_UNTIL（--compat）"
    log "    处理方式：按上面的「应对」改配置；或把 --compat 提到 v$_v；或改用固定版本"
    log "    本次未做任何改动，退出码 3"
    exit 3
  done <<EOF
$_rows
EOF
  return 0
}

# 跨版本提示：记住每个更新目标上次跑过的版本，若本次版本更高且两者之间存在
# behavior 级破坏性变更，主动在日志里说明（不中止，仅提示，每个版本提示一次）。
compat_notice() {
  _dir="$1"
  [ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null || return 0
  _lf="$_dir/lastver"
  _prev=""
  [ -f "$_lf" ] && _prev=$(cat "$_lf" 2>/dev/null)
  case "$_prev" in ''|*[!0-9.]*) _prev="" ;; esac
  if [ -n "$_prev" ] && ! ver_gt "$VERSION" "$_prev"; then
    return 0                      # 同版本或更旧：不提示
  fi
  if [ -n "$_prev" ]; then
    _rows=$(compat_rows behavior)
    if [ -n "$_rows" ]; then
      while IFS='|' read -r _v _t _n _d; do
        [ -n "$_v" ] || continue
        ver_gt "$_v" "$_prev" || continue
        ver_ge "$VERSION" "$_v" || continue
        log "WARN 你从 $VERSION 之前的版本(${_prev})升级上来，v$_v 引入了破坏性变更"
        log "     变更：$_d"
        log "     应对：$_n"
        # 注意：不能建议「加 --compat $_prev」——那会让 compat_gate 判定
        # 「存在比声明版本更新的破坏性变更」而硬停 rc=3，等于把用户锁死在
        # 升级后的第一轮。正确做法只有两条：接受新行为，或把下载地址固定回旧版。
        log "     本次仍会继续执行。两条路选一条："
        log "       1) 接受上面的新做法（想让下一次破坏性变更前先停住，可加 --compat $VERSION）"
        log "       2) 想继续用旧行为，把下载地址固定到 v$_prev 那个 tag"
      done <<EOF
$_rows
EOF
    fi
  fi
  printf '%s\n' "$VERSION" > "$_lf" 2>/dev/null || true
  return 0
}

usage() {
  cat <<'USAGE'
DPanel 定时任务自动更新脚本

跑一轮更新就结束，触发频率交给 DPanel 的「计划任务」配置。
同一目标只挂一个计划任务即可（脚本内部不再加锁，并发由 DPanel 保证）。

用法：
  container-autoupdate.sh --compose <项目名>     更新一个 Compose 项目
  container-autoupdate.sh --container <容器名>   更新一个普通容器
  container-autoupdate.sh --help                 显示本帮助

目标也可以写在文件顶部配置区（COMPOSE_NAME / CONTAINER_NAME），或用环境变量
UPD_COMPOSE / UPD_CONTAINER 指定。优先级：命令行 > 环境变量 > 配置区。
两种目标必须且只能指定一个。

选项：
  --compose <名>         Compose 项目名（Docker Compose 的 project name）
  --container <名>       容器名
  --compose-dir <目录>   Compose 项目目录；默认从容器 label 自动发现
  --docker-sock <路径>   Docker socket 路径；默认读 DOCKER_HOST 或 /var/run/docker.sock
  --dry-run              只检查有没有新版本，不做任何改动
  --bad-ttl-days <天数>  失败版本钉住多少天后自动解除（默认 7）
  --pull-retries <次数>   拉取失败后重试几次（默认 1；0 = 不重试）
  --state-dir <目录>     事务状态目录（默认 /tmp/.container-autoupdate）
  --compat <版本>        声明只验证到某个版本；脚本若含更新的破坏性变更就中止
  -h, --help             显示本帮助
  -V, --version          显示版本

环境变量：
  UPD_COMPOSE / UPD_CONTAINER   目标（同命令行）
  COMPOSE_DIR                   同 --compose-dir
  COMPOSE_BASE                  Compose 项目目录的兜底根路径；留空则只用容器 label 发现
  DOCKER_SOCK                   同 --docker-sock
  DOCKER_HOST                   支持 unix:///path 与 tcp://host:port
  STATE_ROOT                    同 --state-dir
  DRY_RUN=1                     同 --dry-run
  BAD_TTL_DAYS                  同 --bad-ttl-days
  PULL_RETRIES                  同 --pull-retries
  DIGEST_RETRIES                查远端 digest 失败后重试几次（默认 2；0 = 不重试）
  DIGEST_RETRY_WAIT             查远端 digest 重试间隔秒数（默认 5）
  COMPAT_UNTIL                  同 --compat
  T_HARD / T_INSPECT / T_STALL / T_PULL_MAX / T_UP / T_HEALTH / T_ROLLBACK
                                各阶段超时（秒），一般不用改
  HEALTH_TRIES                  健康门禁最多轮询几次；默认 0 = 只受 T_HEALTH 秒数约束
  PLAIN_BOOT                    无 healthcheck 的容器启动后观察多少秒（默认 30）

退出码：
  0  成功，或无需更新，或按规则跳过
  1  配置/环境错误，或本轮未能完成更新（容器保持原样）
  2  回滚本身失败，需要人工介入（现场保留在 --state-dir）
  3  检测到破坏性变更，你的调用方式已失效（本次未做任何改动，日志里有迁移说明）
  130  被 Ctrl-C（SIGINT）中断
  143  被 SIGTERM / SIGHUP 中断（计划任务执行超时常见）

关于版本与兼容：
  脚本每次运行都会把版本号写进日志（首行 `container-autoupdate v<x.y.z> 启动`）。
  如果新版引入了会破坏你已有调用方式的变更，脚本会主动识别并在输出里给出
  迁移方式，而不是静默忽略旧写法。想彻底避免意外，把下载地址固定到某个 tag
  （见 README「版本与升级」）。

示例：
  # DPanel 计划任务里跑（推荐）：把下面这条命令填进计划任务的「命令」，
  # 由 DPanel 按你设定的周期触发。
  container-autoupdate.sh --compose myapp

  # 手动跑一轮（单次更新，跑完就结束；不建议再套 cron / systemd timer）
  container-autoupdate.sh --compose myapp

  # 直接跑远程脚本，跟随最新发布版（地址不含版本号，粘贴即用）
  curl -fsSL -L https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh \
    | sh -s -- --compose myapp

  # 生产环境想锁死版本：把上面的 latest/download 换成带版本号的路径
  # releases/download/v1.2.3/container-autoupdate.sh
  # -L 不能省：latest/download 会返回 302 跳转。
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
      --compose-dir)  [ "$#" -ge 2 ] || { echo "ERR --compose-dir 缺少参数" >&"$ERR_FD"; exit 1; }
                      COMPOSE_DIR="$2"; shift 2 ;;
      --docker-sock)  [ "$#" -ge 2 ] || { echo "ERR --docker-sock 缺少参数" >&"$ERR_FD"; exit 1; }
                      DOCKER_SOCK="$2"; shift 2 ;;
      --state-dir)    [ "$#" -ge 2 ] || { echo "ERR --state-dir 缺少参数" >&"$ERR_FD"; exit 1; }
                      STATE_ROOT="$2"; shift 2 ;;
      --bad-ttl-days) [ "$#" -ge 2 ] || { echo "ERR --bad-ttl-days 缺少参数" >&"$ERR_FD"; exit 1; }
                      BAD_TTL_DAYS="$2"; shift 2 ;;
      --pull-retries) [ "$#" -ge 2 ] || { echo "ERR --pull-retries 缺少参数" >&"$ERR_FD"; exit 1; }
                      PULL_RETRIES="$2"; shift 2 ;;
      --compat)       [ "$#" -ge 2 ] || { echo "ERR --compat 缺少参数" >&"$ERR_FD"; exit 1; }
                      COMPAT_UNTIL="$2"; _SAW_COMPAT=1; shift 2 ;;
      --dry-run)      DRY_RUN=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      -V|--version)   echo "$VERSION"; exit 0 ;;
      *)              compat_removed_flag "$1"
                      echo "ERR 未知参数：$1（用 --help 查看用法）" >&"$ERR_FD"; exit 1 ;;
    esac
  done
  # 命令行上两个目标都显式给过 → 直接拒绝，不做「后者胜出」的静默覆盖
  if [ "$_SAW_COMPOSE" = "1" ] && [ "$_SAW_CONTAINER" = "1" ]; then
    echo "ERR 配置错误：--compose 与 --container 必须且只能给一个" >&"$ERR_FD"
    exit 1
  fi
  # 重试次数必须是非负整数。给错值要立刻报错，不能悄悄当成 0 或 1。
  case "$PULL_RETRIES" in
    ''|*[!0-9]*) echo "ERR --pull-retries 必须是非负整数（当前值=$PULL_RETRIES）" >&"$ERR_FD"; exit 1 ;;
  esac
}

# 解析 Docker 端点：unix socket 或 tcp，供 dcurl 统一调用。
resolve_docker_endpoint() {
  if [ -n "$DOCKER_SOCK" ]; then
    SOCK="$DOCKER_SOCK"; API_HOST="http://localhost"
    export DOCKER_HOST="unix://$SOCK"   # 让 docker CLI 与 API 调用指向同一个端点
    return 0
  fi
  case "${DOCKER_HOST:-}" in
    unix://*) SOCK="${DOCKER_HOST#unix://}"; API_HOST="http://localhost" ;;
    tcp://*)  SOCK=""; API_HOST="http://${DOCKER_HOST#tcp://}" ;;
    http://*|https://*) SOCK=""; API_HOST="$DOCKER_HOST" ;;
    "")       SOCK="/var/run/docker.sock"; API_HOST="http://localhost" ;;
    *)        SOCK=""; API_HOST="http://${DOCKER_HOST#*://}" ;;
  esac
  return 0
}

# 统一 Docker API 调用入口：走 unix socket 时加 --unix-socket，走 tcp 时直连。
dcurl() {
  if [ -n "$SOCK" ]; then
    curl --unix-socket "$SOCK" "$@"
  else
    curl "$@"
  fi
}

check_deps() {
  _missing=""
  for _b in docker curl timeout sed awk grep; do
    command -v "$_b" >/dev/null 2>&1 || _missing="$_missing $_b"
  done
  if [ -n "$_missing" ]; then
    echo "ERR 缺少依赖命令：$_missing" >&"$ERR_FD"
    echo "    需要 docker / curl / timeout 以及 busybox 或 coreutils 基础工具" >&"$ERR_FD"
    exit 1
  fi
  if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    echo "ERR 无法连接 Docker（socket=${SOCK:-$API_HOST}）" >&"$ERR_FD"
    echo "    请确认 Docker 正在运行，且当前用户有权限访问 socket" >&"$ERR_FD"
    exit 1
  fi
  # buildx 是「查远端 digest」的唯一手段（remote_digest 用它读 manifest）。
  # 缺它时 digest 会恒为空，脚本每轮都报「无法获取远端 digest」而不更新——
  # 那个错误信息会把人引向网络问题，所以必须在动手之前就把原因说清楚。
  if ! docker buildx version >/dev/null 2>&1; then
    echo "ERR 缺少 docker buildx 插件（查询远端 digest 依赖它）" >&"$ERR_FD"
    echo "    Debian/Ubuntu：apt install docker-buildx-plugin" >&"$ERR_FD"
    echo "    其他发行版：https://github.com/docker/buildx/releases 下载后放进 \$HOME/.docker/cli-plugins/" >&"$ERR_FD"
    exit 1
  fi
}

parse_args "$@"
resolve_docker_endpoint
mkdir -p "$STATE_ROOT"

# 每次真实运行都在日志里留一行版本号：排查历史问题时，能立刻看出那一轮
# 跑的是哪一版脚本（升级过 latest 之后尤其重要）。
log "container-autoupdate v$VERSION 启动"

# 破坏性变更防线（顺序很重要）：
#   1. 旧环境变量还在设 → 说明用户仍按旧文档调用，立刻中止并给出新写法
#   2. --compat 声明的版本比脚本旧、且中间有 behavior 级变更 → 中止
compat_removed_env
compat_gate

# 每个目标一个版本记录目录，用于「跨版本提示」。
# 必须与事务目录（compose_update 的 $STATE_ROOT/compose-<名>、plain_update 的
# $STATE_ROOT/plain-<名>）分开：事务目录在成功收尾时会被整目录 rm -rf，放在
# 里面会导致 lastver 每轮都被删掉、跨版本提示永远不触发。
compat_state_dir() {
  if [ -n "$COMPOSE_NAME" ] && [ -z "$CONTAINER_NAME" ]; then
    printf '%s/compat/compose-%s' "$STATE_ROOT" "$(safe_key "$COMPOSE_NAME")"
  elif [ -z "$COMPOSE_NAME" ] && [ -n "$CONTAINER_NAME" ]; then
    printf '%s/compat/plain-%s' "$STATE_ROOT" "$(safe_key "$CONTAINER_NAME")"
  else
    printf '%s/compat' "$STATE_ROOT"
  fi
}

# ---------- 镜像引用 / digest ----------
split_ref() {
  _r="$1"
  case "$_r" in *@*) _r="${_r%%@*}" ;; esac
  _rest="${_r##*/}"
  case "$_rest" in
    *:*) echo "${_r%:*} ${_rest##*:}" ;;
    *)   echo "$_r latest" ;;
  esac
}

remote_digest() {
  timeout -s KILL "$T_INSPECT" docker buildx imagetools inspect "$1" 2>/dev/null \
    | sed -n 's/^Digest:  *//p' | head -n1
}

# 查远端 digest 是个纯网络请求，最容易遇到瞬时故障（连接被重置、镜像源超时、
# DNS 抖动）。一次失败就放弃整轮太脆——生产上就因为一次取 digest 失败让
# 整轮更新直接结束。所以这里按 DIGEST_RETRIES 重试几次（间隔几秒）。
# 重试次数为 0 时行为与以前完全一样（只查一次）。
#
# 结果放在全局变量 DIGEST_RESULT 里，不用 echo 返回：
# 这个函数是在 $( ) 里调用的，而 log() 写的是 stdout——
# 用 echo 返回的话，重试提示会被一起收进「digest」里，把结果弄脏。
DIGEST_RETRIES="${DIGEST_RETRIES:-2}"
DIGEST_RETRY_WAIT="${DIGEST_RETRY_WAIT:-5}"
DIGEST_RESULT=""
remote_digest_retry() {
  DIGEST_RESULT=""
  _dimg="$1"
  _dtries=$(( ${DIGEST_RETRIES:-2} + 1 ))
  _dn=1
  while [ "$_dn" -le "$_dtries" ]; do
    DIGEST_RESULT=$(remote_digest "$_dimg")
    [ -n "$DIGEST_RESULT" ] && return 0
    if [ "$_dn" -ge "$_dtries" ]; then break; fi
    log "   查远端 digest 失败（$_dimg），${DIGEST_RETRY_WAIT}s 后重试（第 $_dn/${_dtries} 次尝试）"
    sleep "$DIGEST_RETRY_WAIT"
    _dn=$(( _dn + 1 ))
  done
  return 1
}

is_current() {
  [ -z "$1" ] && return 1
  docker image inspect "$1" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
    | sed 's/^[^@]*@//' | grep -Fxq "$2"
}

is_pinned_bad() {
  _bid=$(docker image inspect -f '{{.Id}}' "$1:bad" 2>/dev/null) || return 1
  [ -n "$_bid" ] || return 1
  is_current "$_bid" "$2"
}

bad_meta() { echo "$STATE_ROOT/bad-$(safe_key "$1").time"; }

pin_bad() {   # $1=repo $2=image ID（必须非空）
  [ -n "$2" ] || return 0
  if docker tag "$2" "$1:bad" 2>/dev/null; then
    now > "$(bad_meta "$1")"
    log "已把失败版本钉为 $1:bad"
  fi
}

expire_bad() {
  _bad="$1:bad"
  _bid=$(docker image inspect -f '{{.Id}}' "$_bad" 2>/dev/null) || return 0
  [ -n "$_bid" ] || return 0
  _meta=$(bad_meta "$1")
  [ -f "$_meta" ] || return 0       # 没有钉住时间时保守保留，不看镜像构建时间
  _at=$(cat "$_meta" 2>/dev/null)
  case "$_at" in ''|*[!0-9]*) return 0 ;; esac
  _age=$(( ( $(now) - _at ) / 86400 ))
  if [ "$_age" -ge "$BAD_TTL_DAYS" ]; then
    log "解除已钉住 ${_age} 天的坏版本 $_bad"
    docker rmi "$_bad" >/dev/null 2>&1 || true
    rm -f "$_meta"
  fi
  return 0
}

clean_orphans() {
  # 清理「属于本仓库、已无任何容器引用、且不带保留标签、也不再被任何 tag 指着」的镜像。
  #
  # 三个坑（都真实踩过）：
  #   1. `dangling=true` 与 `--filter reference=` 语义互斥，组合起来永远命中不了（AGENTS.md §3 NEVER）。
  #   2. `:prev`（回滚点）、`:bad`（坏版本钉子）、`:rollback-pending`（更新中占位）
  #      通常只有一个标签、也没有容器引用，但它们**必须保留**。
  #      按「单标签即孤儿」判定会把回滚点删掉——生产 magpie 的 :prev 就这么没的。
  #   3. **N-2 会变成 <none>:<none>**：每次更新把 :prev 往前搬一格，更早那版就失去最后一个
  #      标签、变成 dangling。它仍然带着 RepoDigests（形如 `repo@sha256:...`），但
  #      `docker images --format '{{.Repository}}:{{.Tag}}'` 只会给出 `<none>:<none>`，
  #      所以「按 repo:tag 前缀匹配」永远看不到它 → 每成功更新一次就白留一个完整镜像。
  #      正因如此，这里必须**先用 RepoDigests 认领归属**，再退回标签前缀匹配。
  _repo="$1"; _n=0
  [ -n "$_repo" ] || return 0

  # ① 按 RepoDigests 认领：涵盖已变 <none> 的 N-2 以及仍有标签的镜像
  _refs=$(docker images -a --format '{{.ID}}' 2>/dev/null | sort -u | while read -r _i; do
    [ -n "$_i" ] || continue
    _rd=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$_i" 2>/dev/null)
    case "$_rd" in
      *"${_repo}@"*) echo "$_i" ;;
    esac
  done)
  # ② 兜底：还没有 RepoDigests 记录的本地构建/导入镜像，只能靠标签前缀
  _refs=$(printf '%s\n%s\n' "$_refs" \
          "$(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null \
             | awk -v r="$_repo" '$2 ~ ("^" r ":") { print $1 }')" \
          | awk 'NF' | sort -u)

  for _id in $_refs; do
    # 仍有容器（含已停止）在用它：不动
    [ -n "$(docker ps -a -q --filter ancestor="$_id" 2>/dev/null)" ] && continue
    _tags=$(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null \
            | awk -v i="$_id" '$1 == i { print $2 }' | sort -u)
    # 带保留标签的一律不动（回滚点 / 坏版本钉子 / 更新占位）
    _keep=0
    for _t in $_tags; do
      case "$_t" in
        "${_repo}:prev"|"${_repo}:bad"|"${_repo}:rollback-pending") _keep=1 ;;
      esac
    done
    [ "$_keep" = "1" ] && continue
    # 还有别的 tag 指着它：说明不是孤儿，只是多标签，不动
    _cnt=$(printf '%s\n' "$_tags" | grep -c . || true)
    [ "$_cnt" -le 1 ] || continue
    docker rmi "$_id" >/dev/null 2>&1 && _n=$((_n + 1))
  done
  [ "$_n" -gt 0 ] && log "清理孤儿镜像 $_n 个（$_repo）"
  return 0
}

# 收集本轮涉及的全部镜像仓库名（compose 多镜像项目时不能只清最后一个）。
_all_repos() {
  if [ -n "${C_MAP:-}" ] && [ -f "${C_MAP:-}" ]; then
    awk -F'|' '{ print $3 }' "$C_MAP" 2>/dev/null | sort -u
  fi
  return 0
}

# ---------- Docker API 版本 ----------
api_negotiate() {
  _v=$(dcurl -s --max-time 10 "$API_HOST/version" 2>/dev/null \
       | sed -n 's/.*"ApiVersion":"\([0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' | head -n1)
  [ -n "$_v" ] || _v="1.47"
  API="$API_HOST/v${_v}"
  _maj=${_v%%.*}; _min=${_v#*.}
  if [ "$_maj" -lt 2 ] && [ "$_min" -lt 47 ]; then
    log "ERR 容器安全重建需要 Docker API >= 1.47，当前=$_v"
    return 1
  fi
  return 0
}

# ---------- 拉取：只管理本轮 PID ----------
# $4 可选：本次拉取的绝对截止时刻。compose 多镜像项目要按剩余镜像数分摊全局预算，
# 否则第一个镜像能把整份预算吃光，后面的镜像一上来就「达到拉取上限」——
# 那是必然失败，不是偶发。
pull_stream() {
  _repo="$1"; _tag="$2"; _log="$3"; _dl="${4:-}"
  PULL_DIGEST=""; PULL_MSG=""; PULL_KIND=""
  _enc=$(printf '%s' "$_repo" | sed 's|/|%2F|g')
  : > "$_log"
  _seen=0; _seen_at=$(now)
  _cap=$(( $(now) + T_PULL_MAX ))
  _hard=$(( START + T_HARD - (T_UP + T_HEALTH + T_ROLLBACK + 15) ))
  [ "$_hard" -lt "$_cap" ] && _cap=$_hard
  if [ -n "$_dl" ]; then
    case "$_dl" in ''|*[!0-9]*) ;; *) [ "$_dl" -lt "$_cap" ] && _cap=$_dl ;; esac
  fi
  # 预算要先算出来再起 curl：curl 必须自带 --max-time，
  # 否则脚本被 kill 时它还活着（后台函数的 $! 只是那个子 shell 的 PID，
  # kill -9 杀不到它真正 fork 出来的 curl），残留进程会一直占着资源。
  _mt=$(( _cap - $(now) ))
  [ "$_mt" -lt 1 ] && _mt=1
  if [ -n "$SOCK" ]; then
    curl --unix-socket "$SOCK" -sN --max-time "$_mt" -X POST \
      "$API/images/create?fromImage=${_enc}&tag=${_tag}" >> "$_log" 2>&1 &
  else
    curl -sN --max-time "$_mt" -X POST \
      "$API/images/create?fromImage=${_enc}&tag=${_tag}" >> "$_log" 2>&1 &
  fi
  _pid=$!
  while kill -0 "$_pid" 2>/dev/null; do
    sleep 5
    _t=$(now); _sz=$(wc -c < "$_log" 2>/dev/null | tr -d ' ')
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    if [ "$_sz" -gt "$_seen" ]; then _seen=$_sz; _seen_at=$_t; fi
    _idle=$((_t - _seen_at))
    if [ "$_idle" -ge "$T_STALL" ]; then
      kill -9 "$_pid" 2>/dev/null || true; wait "$_pid" 2>/dev/null || true
      PULL_MSG="进度停滞 ${_idle}s（共收 ${_seen} 字节后无新增）"
      PULL_KIND="stall"
      return 1
    fi
    if [ "$_t" -ge "$_cap" ]; then
      kill -9 "$_pid" 2>/dev/null || true; wait "$_pid" 2>/dev/null || true
      PULL_MSG="达到拉取上限（共收 ${_seen} 字节）"
      PULL_KIND="cap"
      return 1
    fi
  done
  wait "$_pid" 2>/dev/null
  _rc=$?
  # 先看拉取流自己报告了什么，再看 curl 的退出码。
  # 顺序不能反：镜像源明确说「manifest unknown」时，curl 很可能同时以非 0 退出，
  # 如果先看退出码，就会把它当成瞬时故障去重试 —— 而重试一万次也一样。
  _err=$(sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$_log" | head -n1)
  if [ -n "$_err" ]; then
    PULL_MSG="镜像源返回错误：$_err"
    # 「error」字段有两种含义，必须分开看：
    #   永久性（镜像不存在、仓库名错、鉴权失败）→ 重试一万次也一样，不重试；
    #   瞬时性（429 限流、5xx、上游抖动）        → 重试一次通常就成了。
    # 靠关键字区分：这些措辞出现时基本不会是瞬时的。
    case "$_err" in
      *not\ found*|*notfound*|*"not found"*|*"manifest unknown"*|*"no such"*|\
      *unauthorized*|*denied*|*"authentication required"*|*"access denied"*|\
      *"repository does not exist"*|*"does not exist"*|*unknown\ blob*|*unknown\ manifest*)
        PULL_KIND="permanent"
        ;;
      *)
        PULL_KIND="transient"
        ;;
    esac
    return 1
  fi
  if [ "$_rc" -ne 0 ]; then PULL_MSG="拉取流退出 rc=$_rc"; PULL_KIND="transient"; return 1; fi
  PULL_DIGEST=$(sed -n 's/.*"status":"Digest: \(sha256:[0-9a-f]\{64\}\)".*/\1/p' "$_log" | tail -n1)
  if [ -z "$PULL_DIGEST" ]; then
    PULL_MSG="拉取流结束但没有报告 digest（共收 ${_seen} 字节）"
    PULL_KIND="transient"
    return 1
  fi
  PULL_MSG="已完成（共收 ${_seen} 字节）"
  PULL_KIND="ok"
  return 0
}

# 拉取失败后重试。
# 参数：$1=repo $2=tag $3=日志文件 $4=首次尝试的绝对截止时刻（可空）
#       $5=重试时的绝对截止时刻（可空，缺省按全局剩余预算算）
# 返回值与 PULL_DIGEST / PULL_MSG 的语义与 pull_stream 一致。
#
# 为什么要重试：实测拉取失败绝大多数是「网络抖动 / 镜像源瞬时 5xx / 拉取流中途断开」
# 这类**瞬时**故障，重试一次通常就成了。原实现失败即放弃这一轮，
# 等下一次计划任务（可能一小时后）才有机会，用户体感是「更新总是失败」。
#
# 但不能无脑重试：
#   1. 时间预算不够就不重试 —— 重试必须有预算，否则计划任务会被拖到超时被杀，
#      下一轮又接着超时。留给健康门禁和回滚的部分必须先扣掉。
#   2. 明确是「重试也没用」的错误不重试 —— 镜像不存在、仓库名错、鉴权失败，
#      重试只是白等。这类错误在拉取流里以 "error" 字段返回。
#   3. 拉取卡死不重试 —— 卡死不是瞬时故障，重试大概率还是卡死。
#   4. 两次尝试之间要等一下 —— 立刻重试往往还是同样的失败（源还在限流）。
#   5. 重试要有自己的时间份额 —— 首次尝试的截止时刻是「这个镜像分到的份额」，
#      第一次拉取很可能已经把它用光了；直接拿同一时刻做第二次尝试会秒失败。
pull_with_retry() {
  _repo="$1"; _tag="$2"; _log="$3"; _dl="${4:-}"; _retry_dl="${5:-}"
  # 全局硬截止：留给 T_UP / T_HEALTH / T_ROLLBACK 的部分不能被拉取吃掉。
  _hard_dl=$(( START + T_HARD - (T_UP + T_HEALTH + T_ROLLBACK + 15) ))
  [ -n "$_retry_dl" ] || _retry_dl="$_hard_dl"
  _try=0
  _max_try=$(( PULL_RETRIES + 1 ))
  while :; do
    _try=$((_try + 1))
    if [ "$_try" -gt 1 ]; then _dl="$_retry_dl"; fi
    if pull_stream "$_repo" "$_tag" "$_log" "$_dl"; then
      [ "$_try" -gt 1 ] && log "   拉取第 $_try 次尝试成功"
      return 0
    fi
    _why="$PULL_MSG"
    _kind="$PULL_KIND"
    # 永久性错误不重试：重试也不会成功，只是白等。
    case "$_kind" in
      permanent)
        log "ERR 拉取失败 $_repo:$_tag：$_why"
        log "   这是镜像源明确返回的错误（镜像/仓库不存在、鉴权失败之类），重试没有意义，本轮放弃"
        PULL_MSG="$_why"
        return 1 ;;
      stall)
        # 卡死不是瞬时故障：重试大概率还是卡死，把预算耗光不如留给下一轮。
        log "ERR 拉取失败 $_repo:$_tag：$_why"
        log "   拉取卡死重试也没意义，本轮放弃"
        PULL_MSG="$_why"
        return 1 ;;
    esac
    if [ "$_try" -ge "$_max_try" ]; then
      log "ERR 拉取失败 $_repo:$_tag：$_why（已尝试 $_try 次）"
      PULL_MSG="$_why"
      return 1
    fi
    # 预算不够就别重试了：把剩下的时间留给健康门禁和回滚，比再赌一次拉取重要。
    _need=$(( T_UP + T_HEALTH + T_ROLLBACK + 15 ))
    if [ "$(left)" -le "$_need" ]; then
      log "ERR 拉取失败 $_repo:$_tag：$_why"
      log "   剩余预算 $(left)s 不足以再做一次拉取（需要 $_need s），本轮放弃"
      PULL_MSG="$_why"
      return 1
    fi
    # 这次尝试至少得留 20 秒，否则拉流刚起就到期，等于白等。
    if [ $(( _retry_dl - $(now) )) -lt 20 ]; then
      log "ERR 拉取失败 $_repo:$_tag：$_why"
      log "   剩余预算不足以再做一次有意义的拉取，本轮放弃"
      PULL_MSG="$_why"
      return 1
    fi
    log "WARN 拉取失败 $_repo:$_tag：$_why"
    log "   将在 10 秒后重试（第 $((_try + 1))/${_max_try} 次尝试）"
    sleep 10
  done
}

# ===========================================================================
# 容器分支：声明式重建模板
# ===========================================================================
# Config.Volumes 不复制 inspect 的合并结果；实际挂载由 HostConfig.Mounts 表达。
# 默认 Hostname 等于自身短 ID 时归零，让新容器重新生成。
CONFIG_BODY_TPL='{"Hostname":{{if eq .Config.Hostname "__SHORT__"}}""{{else}}{{json .Config.Hostname}}{{end}},"Domainname":{{json .Config.Domainname}},"User":{{json .Config.User}},"AttachStdin":{{json .Config.AttachStdin}},"AttachStdout":{{json .Config.AttachStdout}},"AttachStderr":{{json .Config.AttachStderr}},"ExposedPorts":{{json .Config.ExposedPorts}},"Tty":{{json .Config.Tty}},"OpenStdin":{{json .Config.OpenStdin}},"StdinOnce":{{json .Config.StdinOnce}},"Env":{{json .Config.Env}},"Cmd":{{json .Config.Cmd}},"Image":{{json .Config.Image}},"Volumes":null,"WorkingDir":{{json .Config.WorkingDir}},"Entrypoint":{{json .Config.Entrypoint}},"OnBuild":{{json .Config.OnBuild}},"Labels":{{json .Config.Labels}},"StopSignal":{{json .Config.StopSignal}},"StopTimeout":{{json .Config.StopTimeout}},"Healthcheck":{{json .Config.Healthcheck}},"Shell":{{json .Config.Shell}},"NetworkDisabled":{{json .Config.NetworkDisabled}},"ArgsEscaped":{{json .Config.ArgsEscaped}}}'

HOST_PRE_TPL='{"Binds":null,"ContainerIDFile":"","LogConfig":{{json .HostConfig.LogConfig}},"NetworkMode":{{if eq .HostConfig.NetworkMode "default"}}"bridge"{{else}}{{json .HostConfig.NetworkMode}}{{end}},"PortBindings":{{json .HostConfig.PortBindings}},"RestartPolicy":{{json .HostConfig.RestartPolicy}},"AutoRemove":{{json .HostConfig.AutoRemove}},"VolumeDriver":{{json .HostConfig.VolumeDriver}},"VolumesFrom":null,"ConsoleSize":{{json .HostConfig.ConsoleSize}},"CapAdd":{{json .HostConfig.CapAdd}},"CapDrop":{{json .HostConfig.CapDrop}},"CgroupnsMode":{{json .HostConfig.CgroupnsMode}},"Dns":{{json .HostConfig.Dns}},"DnsOptions":{{json .HostConfig.DnsOptions}},"DnsSearch":{{json .HostConfig.DnsSearch}},"ExtraHosts":{{json .HostConfig.ExtraHosts}},"GroupAdd":{{json .HostConfig.GroupAdd}},"IpcMode":{{json .HostConfig.IpcMode}},"Cgroup":{{json .HostConfig.Cgroup}},"Links":{{json .HostConfig.Links}},"OomScoreAdj":{{json .HostConfig.OomScoreAdj}},"PidMode":{{json .HostConfig.PidMode}},"Privileged":{{json .HostConfig.Privileged}},"PublishAllPorts":{{json .HostConfig.PublishAllPorts}},"ReadonlyRootfs":{{json .HostConfig.ReadonlyRootfs}},"SecurityOpt":{{json .HostConfig.SecurityOpt}},"UTSMode":{{json .HostConfig.UTSMode}},"UsernsMode":{{json .HostConfig.UsernsMode}},"ShmSize":{{json .HostConfig.ShmSize}},"Sysctls":{{json (index .HostConfig "Sysctls")}},"Runtime":{{json .HostConfig.Runtime}},"Isolation":{{json .HostConfig.Isolation}},"CpuShares":{{json .HostConfig.CpuShares}},"Memory":{{json .HostConfig.Memory}},"NanoCpus":{{json .HostConfig.NanoCpus}},"CgroupParent":{{json .HostConfig.CgroupParent}},"BlkioWeight":{{json .HostConfig.BlkioWeight}},"BlkioWeightDevice":{{json .HostConfig.BlkioWeightDevice}},"BlkioDeviceReadBps":{{json .HostConfig.BlkioDeviceReadBps}},"BlkioDeviceWriteBps":{{json .HostConfig.BlkioDeviceWriteBps}},"BlkioDeviceReadIOps":{{json .HostConfig.BlkioDeviceReadIOps}},"BlkioDeviceWriteIOps":{{json .HostConfig.BlkioDeviceWriteIOps}},"CpuPeriod":{{json .HostConfig.CpuPeriod}},"CpuQuota":{{json .HostConfig.CpuQuota}},"CpuRealtimePeriod":{{json .HostConfig.CpuRealtimePeriod}},"CpuRealtimeRuntime":{{json .HostConfig.CpuRealtimeRuntime}},"CpusetCpus":{{json .HostConfig.CpusetCpus}},"CpusetMems":{{json .HostConfig.CpusetMems}},"Devices":{{json .HostConfig.Devices}},"DeviceCgroupRules":{{json .HostConfig.DeviceCgroupRules}},"DeviceRequests":{{json .HostConfig.DeviceRequests}},"MemoryReservation":{{json .HostConfig.MemoryReservation}},"MemorySwap":{{json .HostConfig.MemorySwap}},"MemorySwappiness":{{json .HostConfig.MemorySwappiness}},"OomKillDisable":{{if .HostConfig.OomKillDisable}}true{{else}}false{{end}},"PidsLimit":{{json .HostConfig.PidsLimit}},"Ulimits":{{json .HostConfig.Ulimits}},"CpuCount":{{json .HostConfig.CpuCount}},"CpuPercent":{{json .HostConfig.CpuPercent}},"IOMaximumIOps":{{json .HostConfig.IOMaximumIOps}},"IOMaximumBandwidth":{{json .HostConfig.IOMaximumBandwidth}},"MaskedPaths":{{json .HostConfig.MaskedPaths}},"ReadonlyPaths":{{json .HostConfig.ReadonlyPaths}},"Init":{{json (index .HostConfig "Init")}},"StorageOpt":{{json (index .HostConfig "StorageOpt")}},"Mounts":'

HOST_POST_TPL=',"Tmpfs":{{json .HostConfig.Tmpfs}}}'

MOUNTS_TPL='[{{range $i, $m := .Mounts}}{{if $i}},{{end}}{"Type":{{json $m.Type}},"Source":{{if eq $m.Type "volume"}}{{json $m.Name}}{{else}}{{json $m.Source}}{{end}},"Target":{{json $m.Destination}},"ReadOnly":{{if $m.RW}}false{{else}}true{{end}}{{if eq $m.Type "bind"}},"BindOptions":{"Propagation":{{json $m.Propagation}}}{{end}}}{{end}}]'

make_config_json() {
  _id="$1"
  _short=$(docker inspect -f '{{.Id}}' "$_id" 2>/dev/null | cut -c1-12)
  _tpl=$(printf '%s' "$CONFIG_BODY_TPL" | sed "s/__SHORT__/$_short/g")
  docker inspect -f "$_tpl" "$_id" 2>/dev/null
}

make_host_json() {   # $1=container ID $2=actual|null
  docker inspect -f "$HOST_PRE_TPL" "$1" 2>/dev/null
  if [ "$2" = "actual" ]; then
    docker inspect -f "$MOUNTS_TPL" "$1" 2>/dev/null
  else
    printf 'null\n'
  fi
  docker inspect -f "$HOST_POST_TPL" "$1" 2>/dev/null
}

net_names() {
  docker inspect -f '{{range $n, $_ := .NetworkSettings.Networks}}{{println $n}}{{end}}' "$1" 2>/dev/null | sort
}

net_field() {
  docker inspect -f '{{$n := index .NetworkSettings.Networks "'"$2"'"}}{{json $n.'"$3"'}}' "$1" 2>/dev/null
}

net_value() {
  docker inspect -f '{{$n := index .NetworkSettings.Networks "'"$2"'"}}{{ $n.'"$3"' }}' "$1" 2>/dev/null
}

net_aliases() {
  docker inspect -f '{{$n := index .NetworkSettings.Networks "'"$2"'"}}{{range $n.Aliases}}{{println .}}{{end}}' "$1" 2>/dev/null
}

is_auto_mac() {   # $1=MAC $2=IPv4；空 MAC 视为无需保留
  [ -n "$1" ] || return 0
  [ -n "$2" ] || return 1
  _mac=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  _oldifs=$IFS; IFS=.; set -- $2; IFS=$_oldifs
  [ "$#" -eq 4 ] || return 1
  _expect=$(printf '02:42:%02x:%02x:%02x:%02x' "$1" "$2" "$3" "$4" 2>/dev/null)
  [ "$_mac" = "$_expect" ]
}

# 生成规范化 EndpointsConfig：过滤自身短 ID 别名和自动 MAC，保留显式网络参数。
make_networks_json() {
  _id="$1"
  _short=$(docker inspect -f '{{.Id}}' "$_id" 2>/dev/null | cut -c1-12)
  printf '{'
  _sep=""
  for _net in $(net_names "$_id"); do
    _nid=$(net_field "$_id" "$_net" NetworkID)
    _ipam=$(net_field "$_id" "$_net" IPAMConfig)
    _links=$(net_field "$_id" "$_net" Links)
    _opts=$(net_field "$_id" "$_net" DriverOpts)
    _gw=$(net_field "$_id" "$_net" GwPriority)
    _mac=$(net_value "$_id" "$_net" MacAddress)
    _ip=$(net_value "$_id" "$_net" IPAddress)
    [ "$_mac" = "<no value>" ] && _mac=""
    [ "$_ip" = "<no value>" ] && _ip=""
    _aliases="["; _asep=""
    for _a in $(net_aliases "$_id" "$_net"); do
      [ "$_a" = "$_short" ] && continue
      _aliases="${_aliases}${_asep}$(json_quote "$_a")"; _asep=","
    done
    _aliases="${_aliases}]"
    printf '%s%s:{"NetworkID":%s,"IPAMConfig":%s,"Links":%s,"Aliases":%s,"DriverOpts":%s,"GwPriority":%s' \
      "$_sep" "$(json_quote "$_net")" "${_nid:-null}" "${_ipam:-null}" "${_links:-null}" "$_aliases" "${_opts:-null}" "${_gw:-0}"
    if [ -n "$_mac" ] && ! is_auto_mac "$_mac" "$_ip"; then
      printf ',"MacAddress":%s' "$(json_quote "$_mac")"
    fi
    printf '}'
    _sep=","
  done
  printf '}\n'
}

mount_sig() {
  docker inspect -f '{{range .Mounts}}{{printf "%s|%s|%s|%s|%v|%s|%s|%s\n" .Type .Name .Source .Destination .RW .Propagation .Driver .Mode}}{{end}}' "$1" 2>/dev/null \
    | awk -F'|' '{ if ($1=="volume" && ($8=="z" || $8=="Z" || $8=="")) $8="<auto>"; print }' OFS='|' | sort
}

# 完整规范化规格：Config + HostConfig（Mounts 单独按实际挂载校验）+ 网络。
plain_spec_ok() {   # $1=old ID $2=new ID $3=work dir
  make_config_json "$1" > "$3/old-config"
  make_config_json "$2" > "$3/new-config"
  make_host_json "$1" null > "$3/old-host"
  make_host_json "$2" null > "$3/new-host"
  make_networks_json "$1" > "$3/old-net"
  make_networks_json "$2" > "$3/new-net"
  cmp -s "$3/old-config" "$3/new-config" || { echo "Config 规范化结果不一致"; return 1; }
  cmp -s "$3/old-host" "$3/new-host" || { echo "HostConfig 规范化结果不一致"; return 1; }
  cmp -s "$3/old-net" "$3/new-net" || { echo "网络声明式配置不一致"; return 1; }
  mount_sig "$1" > "$3/old-mounts"
  mount_sig "$2" > "$3/new-mounts"
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    grep -Fqx "$_m" "$3/new-mounts" || { echo "旧挂载未原样保留：$_m"; return 1; }
  done < "$3/old-mounts"
  return 0
}

plain_preflight() {
  P_OLDCID=$(docker inspect -f '{{.Id}}' "$P_NAME" 2>/dev/null)
  [ -n "$P_OLDCID" ] || { log "ERR 容器 $P_NAME 不存在"; EXIT_CODE=1; return 1; }
  _self=$(hostname 2>/dev/null)
  if [ "$P_NAME" = "$_self" ] || { [ -n "$_self" ] && [ "${P_OLDCID#$_self}" != "$P_OLDCID" ]; }; then
    log "SKIP 不能从容器内部更新当前执行脚本所在的容器"
    return 1
  fi
  _st=$(docker inspect -f '{{.State.Status}}' "$P_OLDCID")
  [ "$_st" = "running" ] || { log "SKIP 容器 $P_NAME 当前=$_st，仅处理 running 容器"; return 1; }
  _auto=$(docker inspect -f '{{.HostConfig.AutoRemove}}' "$P_OLDCID")
  [ "$_auto" != "true" ] || { log "SKIP 容器 $P_NAME AutoRemove=true，停止会删除回滚副本"; return 1; }
  _cp=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$P_OLDCID" 2>/dev/null)
  [ -z "$_cp" ] || { log "SKIP 容器 $P_NAME 属于 Compose 项目 $_cp，请改用 COMPOSE_NAME"; return 1; }
  _vf=$(docker inspect -f '{{json .HostConfig.VolumesFrom}}' "$P_OLDCID")
  if [ -n "$_vf" ] && [ "$_vf" != "null" ] && [ "$_vf" != "[]" ]; then
    log "SKIP 容器 $P_NAME 使用 VolumesFrom，为避免改变挂载语义暂不重建"
    return 1
  fi
  P_NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$P_OLDCID")
  case "$P_NETMODE" in
    container:*) log "SKIP 容器 $P_NAME 的 NetworkMode=$P_NETMODE（共享其它容器的网络栈），不能安全替换"; return 1 ;;
  esac

  # 其他容器对目标的网络/legacy link 依赖。
  for _c in $(docker ps -aq 2>/dev/null); do
    [ "$_c" = "$P_OLDCID" ] && continue
    _dep=$(docker inspect -f '{{.HostConfig.NetworkMode}}|{{json .HostConfig.Links}}' "$_c" 2>/dev/null)
    case "$_dep" in
      "container:$P_OLDCID|"*|*"\"/$P_NAME:"*)
        _cn=$(docker inspect -f '{{.Name}}' "$_c" 2>/dev/null | sed 's|^/||')
        log "SKIP 容器 ${_cn:-$_c} 依赖 $P_NAME 的网络或 legacy link，不能安全替换"
        return 1 ;;
    esac
  done

  # tmpfs 挂在 HostConfig.Tmpfs 里，不出现在 .Mounts；配置会原样保留，但内容属内存态，重建必然清空。
  _tmpfs=$(docker inspect -f '{{json .HostConfig.Tmpfs}}' "$P_OLDCID" 2>/dev/null)
  if [ -n "$_tmpfs" ] && [ "$_tmpfs" != "null" ] && [ "$_tmpfs" != "{}" ]; then
    log "WARN 容器 $P_NAME 含 tmpfs 挂载，配置会保留但挂载内数据在重建后清空（与手动重建一致）"
  fi

  # 只处理能完整保留的挂载。
  docker inspect -f '{{range .Mounts}}{{printf "%s|%s|%s|%s|%s\n" .Type .Mode .Driver .Name .Source}}{{end}}' "$P_OLDCID" > "$P_DIR/mount-precheck"
  while IFS='|' read -r _typ _mode _driver _vname _src; do
    [ -n "$_typ" ] || continue
    case "$_typ" in bind|volume) ;; *) log "SKIP 含暂不支持的实际挂载类型=$_typ"; return 1 ;; esac
    case "$_mode" in
      ''|rw|ro) ;;
      z|Z) [ "$_typ" = "volume" ] || { log "SKIP bind 挂载含 SELinux Mode=$_mode，无法可靠重建"; return 1; } ;;
      *) log "SKIP 挂载含无法可靠保留的 Mode=$_mode"; return 1 ;;
    esac
    if [ "$_typ" = "volume" ]; then
      [ -n "$_vname" ] || { log "SKIP 存在无法确定名称的卷"; return 1; }
      case "$_driver" in ''|local) ;; *) log "SKIP 卷使用自定义 driver=$_driver"; return 1 ;; esac
    else
      [ -n "$_src" ] || { log "SKIP 存在空 Source 的 bind 挂载"; return 1; }
    fi
  done < "$P_DIR/mount-precheck"

  # 网络驱动与 MAC 形态。
  for _net in $(net_names "$P_OLDCID"); do
    case "$_net" in ''|*[!A-Za-z0-9_.-]*) log "SKIP 网络名含特殊字符：$_net"; return 1 ;; esac
    _nid=$(net_value "$P_OLDCID" "$_net" NetworkID)
    _driver=$(docker network inspect -f '{{.Driver}}' "$_nid" 2>/dev/null)
    case "$_driver" in bridge|host|null) ;; *) log "SKIP 网络 $_net driver=$_driver 暂不支持"; return 1 ;; esac
    _mac=$(net_value "$P_OLDCID" "$_net" MacAddress)
    _ip=$(net_value "$P_OLDCID" "$_net" IPAddress)
    [ "$_mac" = "<no value>" ] && _mac=""
    [ "$_ip" = "<no value>" ] && _ip=""
    # 只有「显式指定且无法自动重算」的 MAC 才需要保留；Docker 自动生成的 MAC
    # 由「网段基址 02:42 + IPv4 四段」推导得出，重建时让它自己再生成即可。
    # 旧代码用「有 MAC 但无 IPv4 且 bridge → 跳过」间接判据：IPv4 因容器暂停、
    # IPAM 变更等原因缺失时会误判成「无法区分」，把本可安全重建的容器挡在门外。
    # 现在直接问 is_auto_mac：它就是「这个 MAC 是不是自动生成的」的权威判据。
    if [ -n "$_mac" ] && ! is_auto_mac "$_mac" "$_ip"; then
      # 显式 MAC 必须能原样带回（make_networks_json 会写进 MacAddress），
      # 但前提是能确认它不是自动生成的；无 IPv4 时 is_auto_mac 返回 1（保守视为显式），
      # 此时若驱动是 bridge 则无法判断，仍需人工确认。
      if [ -z "$_ip" ] && [ "$_driver" = "bridge" ]; then
        log "SKIP 网络 $_net 有 MAC 但无 IPv4，无法可靠区分自动/显式 MAC"
        return 1
      fi
    fi
  done
  return 0
}

save_plain_state() {
  cat > "$P_STATE" <<EOF
S_NAME=$P_NAME
S_OLDNAME=$P_OLDNAME
S_OLDCID=$P_OLDCID
S_NEWCID=$P_NEWCID
S_OLDIMG=$P_OLDID
S_NEWIMG=$P_NEWID
S_IMG=$P_IMG
S_REPO=$P_REPO
S_STAGE=$P_STAGE
S_STARTED=${P_STARTED:-0}
EOF
}

load_plain_state() {
  . "$P_STATE"
  P_NAME="$S_NAME"; P_OLDNAME="$S_OLDNAME"; P_OLDCID="$S_OLDCID"
  P_NEWCID="$S_NEWCID"; P_OLDID="$S_OLDIMG"; P_NEWID="$S_NEWIMG"
  P_IMG="$S_IMG"; P_REPO="$S_REPO"; P_STAGE="$S_STAGE"
  P_STARTED="${S_STARTED:-0}"
}

plain_remove_state() {
  rm -f "$P_STATE"
  ACTIVE_KIND=""
  # 回滚成功时也保留现场：容器虽已复原，create.json / 新旧规格 / pull.log
  # 仍是「这一轮为什么失败」的唯一证据，删了就没法事后取证。
  # 只有正常成功收尾（没有走回滚）才清整个事务目录。
  if [ "${P_KEEP_EVIDENCE:-0}" = "1" ]; then
    log "回滚现场已保留在 $P_DIR（排查完可手动删除）"
  else
    rm -rf "$P_DIR" 2>/dev/null || true
  fi
  P_KEEP_EVIDENCE=0
}

# 未进入事务前的早退：清掉 preflight 可能写下的临时文件，不留空目录。
plain_discard() {
  ACTIVE_KIND=""
  rm -rf "$P_DIR" 2>/dev/null || true
}

# 无论显式失败还是下轮启动恢复，都只按已知 ID 删除/切换。
plain_recover_current() {
  log "开始恢复容器 $P_NAME 到更新前状态"
  _touched=0
  # create 响应丢失时，仅在规格和镜像都匹配的情况下认领新容器。
  if [ -z "$P_NEWCID" ] && [ -n "${P_OLDNAME:-}" ]; then
    _cand=$(docker inspect -f '{{.Id}}' "$P_NAME" 2>/dev/null)
    if [ -n "$_cand" ] && [ "$_cand" != "$P_OLDCID" ] && [ -n "$P_NEWID" ]; then
      _ci=$(docker inspect -f '{{.Image}}' "$_cand" 2>/dev/null)
      if [ "$_ci" = "$P_NEWID" ] && docker inspect "$P_OLDCID" >/dev/null 2>&1; then
        if plain_spec_ok "$P_OLDCID" "$_cand" "$P_DIR" >/dev/null 2>&1; then
          P_NEWCID="$_cand"; save_plain_state
        fi
      fi
    fi
  fi
  # 任何回滚失败都清掉 ACTIVE_KIND，避免 EXIT trap 对同一事务重复回滚；
  # 状态文件保留，下一轮可继续恢复。
  if [ -n "$P_NEWCID" ]; then
    if docker inspect "$P_NEWCID" >/dev/null 2>&1; then
      timeout -s KILL "$T_ROLLBACK" docker rm -f "$P_NEWCID" >/dev/null 2>&1 || {
        log "CRITICAL 无法删除本轮新容器 $P_NEWCID"; ACTIVE_KIND=""; EXIT_CODE=2; return 1;
      }
      _touched=1
    fi
  fi
  docker inspect "$P_OLDCID" >/dev/null 2>&1 || {
    log "CRITICAL 旧容器 $P_OLDCID 不存在，无法自动回滚"; ACTIVE_KIND=""; EXIT_CODE=2; return 1;
  }
  _occupied=$(docker inspect -f '{{.Id}}' "$P_NAME" 2>/dev/null)
  if [ -n "$_occupied" ] && [ "$_occupied" != "$P_OLDCID" ]; then
    log "CRITICAL 原名称 $P_NAME 被未确认的容器 $_occupied 占用，未强删；请人工处理"
    ACTIVE_KIND=""; EXIT_CODE=2; return 1
  fi
  _oldname=$(docker inspect -f '{{.Name}}' "$P_OLDCID" 2>/dev/null | sed 's|^/||')
  if [ "$_oldname" != "$P_NAME" ]; then
    timeout -s KILL "$T_ROLLBACK" docker rename "$P_OLDCID" "$P_NAME" >/dev/null 2>&1 || {
      log "CRITICAL 旧容器无法恢复原名称"; ACTIVE_KIND=""; EXIT_CODE=2; return 1;
    }
    _touched=1
  fi
  _running=$(docker inspect -f '{{.State.Running}}' "$P_OLDCID" 2>/dev/null)
  if [ "$_running" != "true" ]; then
    timeout -s KILL "$T_ROLLBACK" docker start "$P_OLDCID" >/dev/null 2>&1 || {
      log "CRITICAL 旧容器已恢复名称但启动失败"; ACTIVE_KIND=""; EXIT_CODE=2; return 1;
    }
    _touched=1
  fi
  _ok=$(docker inspect -f '{{.State.Running}}|{{.Image}}' "$P_OLDCID" 2>/dev/null)
  [ "$_ok" = "true|$P_OLDID" ] || {
    log "CRITICAL 回滚后状态校验失败：$_ok"; ACTIVE_KIND=""; EXIT_CODE=2; return 1;
  }
  docker tag "$P_OLDID" "$P_IMG" 2>/dev/null || {
    log "CRITICAL 容器已恢复，但原镜像 tag 还原失败"; ACTIVE_KIND=""; EXIT_CODE=2; return 1;
  }
  if [ "${P_STARTED:-0}" = "1" ] && [ -n "$P_NEWID" ]; then pin_bad "$P_REPO" "$P_NEWID"; fi
  docker rmi "$P_STAGE" >/dev/null 2>&1 || true
  # 回滚现场（create.json / 新旧规格 / pull.log）保留，便于事后取证；只清事务状态。
  P_KEEP_EVIDENCE=1 plain_remove_state
  if [ "$_touched" = "1" ]; then
    log "OK 已恢复旧容器、旧镜像和原名称，回滚校验通过"
  else
    log "OK 容器未被改动（失败发生在切换之前），校验通过"
  fi
  return 0
}

plain_fail() {
  log "WARN 容器 $P_NAME 更新失败：$1"
  plain_recover_current || return 1
  # 回滚成功不等于本轮成功：容器虽已复原，但这一轮确实没更新成。
  # 退出码 1 = 「本轮未能完成更新（容器保持原样）」，监控才不会把它当成功。
  [ "${EXIT_CODE:-0}" = "2" ] || EXIT_CODE=1
  return 0
}

emergency_recover() {
  _rc=$?
  trap - EXIT INT TERM HUP
  if [ "$ACTIVE_KIND" = "plain" ]; then
    plain_recover_current || _rc=2
  elif [ "$ACTIVE_KIND" = "compose" ]; then
    if [ "${C_PHASE:-postup}" = "preup" ]; then
      compose_abort_before_up || _rc=2
    else
      compose_rollback || _rc=2
    fi
  fi
  exit "$_rc"
}
trap 'emergency_recover' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

plain_update() {
  P_NAME="$CONTAINER_NAME"
  case "$P_NAME" in ''|*[!A-Za-z0-9_.-]*) log "ERR 容器名不合法：$P_NAME"; EXIT_CODE=1; return ;; esac
  P_DIR="$STATE_ROOT/plain-$(safe_key "$P_NAME")"
  P_STATE="$P_DIR/state"
  mkdir -p "$P_DIR"
  P_NEWCID=""; P_STARTED=0
  if [ -f "$P_STATE" ]; then
    load_plain_state
    log "发现上次未完成事务，先执行恢复"
    plain_recover_current || return
    P_NEWCID=""
  fi
  plain_preflight || { plain_discard; return; }
  P_OLDID=$(docker inspect -f '{{.Image}}' "$P_OLDCID")
  P_IMG=$(docker inspect -f '{{.Config.Image}}' "$P_OLDCID")
  case "$P_IMG" in *@*) log "SKIP 镜像引用为 digest 形式：$P_IMG"; plain_discard; return ;; esac
  set -- $(split_ref "$P_IMG"); P_REPO="$1"; P_TAG="$2"
  P_PREV="$P_REPO:prev"; P_STAGE="$P_REPO:rollback-pending"
  P_STOP=$(docker inspect -f '{{json .Config.StopTimeout}}' "$P_OLDCID")
  case "$P_STOP" in null|'') P_STOP=10 ;; *[!0-9]*) P_STOP=10 ;; esac
  log "MODE container 容器=$P_NAME 镜像=$P_IMG"

  remote_digest_retry "$P_IMG"
  P_REMOTE="$DIGEST_RESULT"
  [ -n "$P_REMOTE" ] || { log "ERR 无法获取远端 digest（已尝试 ${DIGEST_RETRIES:-2} 次），本轮跳过"; EXIT_CODE=1; plain_discard; return; }
  is_pinned_bad "$P_REPO" "$P_REMOTE" && { log "SKIP 远端版本仍在 :bad 钉住期"; plain_discard; return; }
  is_current "$P_OLDID" "$P_REMOTE" && { log "OK $P_NAME 已是最新 $P_REMOTE"; plain_discard; return; }
  [ "$DRY_RUN" != "1" ] || { log "DRY 发现新版本 $P_REMOTE，不执行"; plain_discard; return; }
  [ "$(left)" -gt $((T_UP + T_HEALTH + T_ROLLBACK + 15)) ] || { log "ERR 剩余时间预算不足，未改动"; EXIT_CODE=1; plain_discard; return; }

  # 从暂存标签开始就建立事务；中断时也能还原被 pull 移动的 tag。
  P_OLDNAME="${P_NAME}__old_$(now)"
  P_NEWID=""
  ACTIVE_KIND="plain"; P_STARTED=0
  save_plain_state
  docker tag "$P_OLDID" "$P_STAGE" 2>/dev/null || { plain_fail "无法暂存旧镜像" || return; return; }
  if ! pull_with_retry "$P_REPO" "$P_TAG" "$P_DIR/pull.log"; then
    plain_fail "拉取失败：$PULL_MSG" || return
    return
  fi
  P_NEWID=$(docker image inspect -f '{{.Id}}' "$P_IMG" 2>/dev/null)
  if [ -z "$P_NEWID" ] || [ "$P_NEWID" = "$P_OLDID" ]; then
    plain_fail "拉取后新镜像 ID 无效，未切换容器" || return
    return
  fi
  if [ -n "$PULL_DIGEST" ]; then
    _got=$(docker image inspect "$P_IMG" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
      | grep -F "${P_REPO}@" | sed 's/^[^@]*@//' | head -n1)
    if [ "$_got" != "$PULL_DIGEST" ]; then
      plain_fail "本地 digest(${_got:-空}) 与拉取流报告($PULL_DIGEST) 不一致" || return
      return
    fi
  fi

  P_STARTED=0
  save_plain_state
  if ! timeout -s KILL "$T_UP" docker rename "$P_OLDCID" "$P_OLDNAME" >/dev/null 2>&1; then
    plain_fail "旧容器改名失败" || return
    return
  fi
  save_plain_state
  if ! timeout -s KILL "$T_UP" docker stop -t "$P_STOP" "$P_OLDCID" >/dev/null 2>&1; then
    plain_fail "停止旧容器失败，未启动新容器" || return
    return
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "$P_OLDCID" 2>/dev/null)" = "false" ] || {
    plain_fail "旧容器停止校验失败，未启动新容器" || return
    return
  }

  # 生成声明式 create body。
  make_config_json "$P_OLDCID" > "$P_DIR/config.json"
  make_host_json "$P_OLDCID" actual > "$P_DIR/host.json"
  make_networks_json "$P_OLDCID" > "$P_DIR/networks.json"
  {
    printf '{"HostConfig":'; cat "$P_DIR/host.json"
    printf ',"NetworkingConfig":{"EndpointsConfig":'; cat "$P_DIR/networks.json"
    printf '},'; sed 's/^{//' "$P_DIR/config.json"
  } > "$P_DIR/create.json"

  save_plain_state
  _resp=$(dcurl -s --max-time "$T_UP" -X POST \
    -H 'Content-Type: application/json' --data-binary @"$P_DIR/create.json" \
    "$API/containers/create?name=$P_NAME" 2>&1)
  P_NEWCID=$(printf '%s' "$_resp" | sed -n 's/.*"Id":"\([0-9a-f]\{64\}\)".*/\1/p' | head -n1)
  save_plain_state
  [ -n "$P_NEWCID" ] || { plain_fail "创建新容器失败：$_resp" || return; return; }

  _reason=$(plain_spec_ok "$P_OLDCID" "$P_NEWCID" "$P_DIR")
  [ $? -eq 0 ] || { plain_fail "启动前规格校验失败：$_reason" || return; return; }
  _actual=$(docker inspect -f '{{.Image}}' "$P_NEWCID" 2>/dev/null)
  [ "$_actual" = "$P_NEWID" ] || { plain_fail "启动前镜像 ID 校验失败" || return; return; }

  timeout -s KILL "$T_UP" docker start "$P_NEWCID" >/dev/null 2>&1 || {
    plain_fail "启动新容器失败" || return; return;
  }
  P_STARTED=1; save_plain_state

  _hc=$(docker inspect -f '{{if .State.Health}}1{{else}}0{{end}}' "$P_NEWCID" 2>/dev/null)
  _r0=$(docker inspect -f '{{.RestartCount}}' "$P_NEWCID" 2>/dev/null)
  if [ "$_hc" = "1" ]; then
    # 等待上限由 T_HEALTH 秒决定（用户可调大，用于应用启动慢的场景）。
    # HEALTH_TRIES>0 时额外加一道「最多轮询几次」的硬上限；默认 0 表示不设，
    # 避免出现「T_HEALTH 调大了但轮询次数先耗尽」的自相矛盾。
    _hc_at=$(now); _i=0; _hr=""
    while :; do
      _hr=$(docker inspect -f '{{.State.Health.Status}}' "$P_NEWCID" 2>/dev/null)
      [ "$_hr" = "healthy" ] && break
      case "$_hr" in unhealthy|exited|dead) break ;; esac
      [ $(( $(now) - _hc_at )) -ge "$T_HEALTH" ] && { _hr="超过 ${T_HEALTH}s 未 healthy"; break; }
      _i=$((_i + 1))
      [ "$HEALTH_TRIES" -gt 0 ] && [ "$_i" -gt "$HEALTH_TRIES" ] && { _hr="轮询次数用尽"; break; }
      [ "$(left)" -le "$T_ROLLBACK" ] && { _hr="预算不足"; break; }
      sleep 5
    done
    [ "$_hr" = "healthy" ] || { plain_fail "健康门禁未通过（$_hr）" || return; return; }
  else
    # 无 healthcheck：按 PLAIN_BOOT 秒的墙钟观察窗，每 2 秒采样一次 Running。
    _boot_at=$(now); _rn=true
    while :; do
      _rn=$(docker inspect -f '{{.State.Running}}' "$P_NEWCID" 2>/dev/null)
      [ "$_rn" = "true" ] || break
      [ $(( $(now) - _boot_at )) -ge "$PLAIN_BOOT" ] && break
      [ "$(left)" -le "$T_ROLLBACK" ] && break
      sleep 2
    done
    _r1=$(docker inspect -f '{{.RestartCount}}' "$P_NEWCID" 2>/dev/null)
    [ "$_rn" = "true" ] || { plain_fail "新容器观察窗内退出" || return; return; }
    [ "${_r1:-0}" = "${_r0:-0}" ] || { plain_fail "新容器观察窗内发生重启" || return; return; }
  fi
  _reason=$(plain_spec_ok "$P_OLDCID" "$P_NEWCID" "$P_DIR")
  [ $? -eq 0 ] || { plain_fail "启动后规格复核失败：$_reason" || return; return; }

  # 成功：先保留当前旧容器为唯一回滚副本，再按 ID 清理上一份。
  if docker tag "$P_OLDID" "$P_PREV" 2>/dev/null; then
    log "回滚点已更新为 $P_PREV"
  else
    log "WARN 回滚点标签 $P_PREV 打标失败；本轮更新已成功，但下次失败将无法回滚到这一版"
  fi
  docker rmi "$P_STAGE" >/dev/null 2>&1 || true
  _rollback_file="$P_DIR/rollback.id"
  if [ -f "$_rollback_file" ]; then
    _prev_cid=$(cat "$_rollback_file" 2>/dev/null)
    if [ -n "$_prev_cid" ] && [ "$_prev_cid" != "$P_OLDCID" ] && docker inspect "$_prev_cid" >/dev/null 2>&1; then
      _pn=$(docker inspect -f '{{.Name}}' "$_prev_cid" | sed 's|^/||')
      _pr=$(docker inspect -f '{{.State.Running}}' "$_prev_cid")
      case "$_pn" in
        "${P_NAME}__old_"[0-9]*)
          if [ "$_pr" = "false" ]; then docker rm "$_prev_cid" >/dev/null 2>&1 && log "已清理上一份回滚容器 $_pn";
          else log "WARN 上一份回滚容器仍在运行，未删除 $_pn"; fi ;;
        *) log "WARN 回滚记录名称异常，未删除 $_prev_cid" ;;
      esac
    fi
  fi
  echo "$P_OLDCID" > "$_rollback_file"
  plain_remove_state
  log "OK 容器 $P_NAME 更新完成且健康（新镜像 $P_NEWID，总耗时 $(elapsed)s）"
  log "   手工回退副本：$P_OLDNAME（ID=$P_OLDCID）"
}

# ===========================================================================
# Compose 分支
# ===========================================================================
C_DIR=""; C_CFILES=""; C_ENVFILE=""; C_MAP=""; C_STATE=""; C_PHASE=""

# 用环境变量表达 -p / -f / --env-file，**不要**拼成一个字符串再交给 shell 分词。
# 拼字符串（`docker compose $args ...`）会让路径里的空格、$、反引号、*、? 被二次解析：
# 实测含空格的 compose 路径下，`docker compose -p x -f /tmp/ca space dir/docker-compose.yaml config`
# 会打印 usage 帮助却**返回 rc=0**——静默出错，比直接失败更危险。
# 这三个变量由 Compose 自己解析，路径含空格也能正确工作（已实测）。
compose_env() {
  COMPOSE_PROJECT_NAME="$COMPOSE_NAME"
  export COMPOSE_PROJECT_NAME
  if [ -n "$C_CFILES" ]; then
    # label 里的多文件本来就是逗号分隔；显式指定分隔符，
    # 避免默认的冒号把含冒号的路径（Windows 挂载、URL）拆错。
    COMPOSE_PATH_SEPARATOR=","
    export COMPOSE_PATH_SEPARATOR
    COMPOSE_FILE="$C_CFILES"
    export COMPOSE_FILE
  fi
  # 注意：COMPOSE_FILE / COMPOSE_ENV_FILES 设成空串会被 Compose 判为非法（rc=1），
  # 所以只在非空时才 export；不设时 Compose 会自己找当前目录的 compose.yaml（DPanel 的布局）。
  if [ -n "$C_ENVFILE" ]; then
    COMPOSE_ENV_FILES="$C_ENVFILE"
    export COMPOSE_ENV_FILES
  fi
  return 0
}
resolve_compose() {
  C_DIR=""; C_CFILES=""; C_ENVFILE=""
  if [ -n "$COMPOSE_DIR" ]; then
    C_DIR="$COMPOSE_DIR"
  fi
  _c=$(docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_NAME}" -q 2>/dev/null | head -n1)
  if [ -n "$_c" ]; then
    [ -n "$C_DIR" ] || C_DIR=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$_c" 2>/dev/null)
    C_CFILES=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$_c" 2>/dev/null)
    C_ENVFILE=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.environment_file"}}' "$_c" 2>/dev/null)
  fi
  # 只有显式配置了 COMPOSE_BASE 才回退到该路径，避免在非 DPanel 环境指向不存在的目录。
  if [ -z "$C_DIR" ] && [ -n "$COMPOSE_BASE" ]; then C_DIR="$COMPOSE_BASE/$COMPOSE_NAME"; fi
  # 找不到目录不算错误，交给调用方给出「请用 --compose-dir」的提示。
  [ -n "$C_DIR" ] && [ -d "$C_DIR" ] || { C_DIR=""; return 0; }
  # 路径含空格不再拒绝：compose 参数改由环境变量传递（见 compose_env），
  # 实测含空格的目录与文件名都能正确解析。
  return 0
}

proj_containers() {
  docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_NAME}" --format '{{.Names}}' 2>/dev/null
}

proj_images() {
  # 必须带超时：compose config 卡住时会把整轮的时间预算耗光，
  # 计划任务会被拖到超时被杀，下一轮又接着卡。
  (cd "$C_DIR" && compose_env && timeout -s KILL "$T_INSPECT" docker compose config --images 2>/dev/null) | awk '!seen[$0]++'
}

local_imgid_for() {
  _ref="$1"; _found=""; _id=""
  for _c in $(proj_containers); do
    _ci=$(docker inspect -f '{{.Config.Image}}' "$_c" 2>/dev/null)
    [ "$_ci" = "$_ref" ] || continue
    _found=1
    _this=$(docker inspect -f '{{.Image}}' "$_c" 2>/dev/null)
    if [ -n "$_id" ] && [ "$_id" != "$_this" ]; then echo "MIXED"; return 0; fi
    _id="$_this"
  done
  [ -n "$_found" ] || return 0
  echo "$_id"
}

compose_health() {
  # 墙钟上限 T_HEALTH 秒（用户可调大，应对启动慢的应用）；
  # HEALTH_TRIES>0 时额外加一道轮询次数硬上限，默认 0 表示不设。
  _up_at=$(now); _i=0
  while :; do
    _all=1
    for _c in $(proj_containers); do
      _s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$_c" 2>/dev/null)
      case "$_s" in
        unhealthy|exited|dead) echo "容器 $_c 状态=$_s"; return 1 ;;
        healthy) ;;
        running) [ $(( $(now) - _up_at )) -lt "$PLAIN_BOOT" ] && _all=0 ;;
        *) _all=0 ;;
      esac
    done
    [ "$_all" = "1" ] && return 0
    [ $(( $(now) - _up_at )) -ge "$T_HEALTH" ] && { echo "超过 ${T_HEALTH}s 未全部 healthy"; return 1; }
    _i=$((_i + 1))
    [ "$HEALTH_TRIES" -gt 0 ] && [ "$_i" -gt "$HEALTH_TRIES" ] && { echo "健康门禁轮询次数用尽"; return 1; }
    [ "$(left)" -le "$T_ROLLBACK" ] && { echo "健康等待预算不足"; return 1; }
    sleep 5
  done
}

compose_stage_tags() {
  while IFS='|' read -r _img _old _repo _tag; do
    docker tag "$_old" "$_repo:rollback-pending" 2>/dev/null || return 1
  done < "$C_MAP"
  return 0
}

compose_restore_tags() {   # $1=1 时才钉 bad；拉取/校验中止不惩罚未运行的新版本
  _pin="${1:-0}"
  while IFS='|' read -r _img _old _repo _tag; do
    _cur=$(docker image inspect -f '{{.Id}}' "$_img" 2>/dev/null)
    if [ "$_pin" = "1" ] && [ -n "$_cur" ] && [ "$_cur" != "$_old" ]; then pin_bad "$_repo" "$_cur"; fi
    docker tag "$_old" "$_img" 2>/dev/null || return 1
    docker rmi "$_repo:rollback-pending" >/dev/null 2>&1 || true
  done < "$C_MAP"
  return 0
}

compose_abort_before_up() {
  compose_restore_tags 0 || { log "WARN 镜像 tag 还原失败，请人工检查"; ACTIVE_KIND=""; C_PHASE=""; return 1; }
  ACTIVE_KIND=""; C_PHASE=""; rm -f "$C_STATE"
  return 0
}

compose_rollback() {
  log "开始回滚 Compose 项目 $COMPOSE_NAME"
  # 回滚失败时清 ACTIVE_KIND 防 EXIT trap 重复回滚；状态文件保留供下一轮继续。
  compose_restore_tags 1 || { log "CRITICAL 回滚 tag 还原失败"; ACTIVE_KIND=""; EXIT_CODE=2; return 1; }
  (cd "$C_DIR" && compose_env && timeout -s KILL "$T_ROLLBACK" docker compose up -d --force-recreate) || {
    log "CRITICAL 回滚 compose up 失败或超时，事务状态已保留"; ACTIVE_KIND=""; EXIT_CODE=2; return 1;
  }
  while IFS='|' read -r _img _old _repo _tag; do
    [ -n "$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_NAME}" --filter "ancestor=$_old" 2>/dev/null)" ] || {
      log "CRITICAL 回滚后没有运行中的旧镜像容器：$_img"; ACTIVE_KIND=""; EXIT_CODE=2; return 1;
    }
  done < "$C_MAP"
  _reason=$(compose_health)
  [ $? -eq 0 ] || { log "CRITICAL 回滚后健康校验失败：$_reason"; ACTIVE_KIND=""; EXIT_CODE=2; return 1; }
  ACTIVE_KIND=""; rm -f "$C_STATE"
  log "OK Compose 回滚完成，旧容器与旧镜像校验通过"
  return 0
}

compose_fail_after_up() {
  log "WARN Compose 更新失败：$1"
  compose_rollback || return 1
  # 同 plain_fail：回滚成功仍属「本轮未能完成更新」。
  [ "${EXIT_CODE:-0}" = "2" ] || EXIT_CODE=1
  return 0
}

compose_discard() {
  # 未进入事务前的早退：清掉本轮临时目录（含 map / pull 日志）。
  rm -rf "$C_WORK" 2>/dev/null || true
}

compose_update() {
  log "MODE compose 项目=$COMPOSE_NAME 目录=$C_DIR"
  C_DIR_SAFE=$(safe_key "$COMPOSE_NAME")
  C_WORK="$STATE_ROOT/compose-$C_DIR_SAFE"
  C_MAP="$C_WORK/map"; C_STATE="$C_WORK/state"
  mkdir -p "$C_WORK"
  if [ -f "$C_STATE" ]; then
    . "$C_STATE"
    log "发现上次未完成的 Compose 事务，先按阶段恢复"
    if [ "${C_PHASE:-postup}" = "preup" ]; then
      compose_abort_before_up
    else
      compose_rollback || return
    fi
  fi

  _cts=$(proj_containers)
  [ -n "$_cts" ] || { log "SKIP 项目 $COMPOSE_NAME 没有容器，不执行首次部署"; compose_discard; return; }
  for _c in $_cts; do
    _st=$(docker inspect -f '{{.State.Status}}' "$_c" 2>/dev/null)
    [ "$_st" = "running" ] || {
      log "SKIP 项目含非 running 容器 $_c（$_st），为避免误判一次性/停止服务，本轮不更新"
      compose_discard
      return
    }
  done
  IMAGES=$(proj_images)
  [ -n "$IMAGES" ] || { log "ERR 无法解析 Compose 镜像清单"; EXIT_CODE=1; compose_discard; return; }
  : > "$C_MAP"
  for IMG in $IMAGES; do
    case "$IMG" in *@*) log "SKIP Compose 含 digest 固定镜像 $IMG，不自动更新整个项目"; compose_discard; return ;; esac
    set -- $(split_ref "$IMG"); REPO="$1"; TAG="$2"
    remote_digest_retry "$IMG"
    REMOTE="$DIGEST_RESULT"
    [ -n "$REMOTE" ] || { log "ERR 无法获取 $IMG 远端 digest（已尝试 ${DIGEST_RETRIES:-2} 次），本轮跳过整个项目"; EXIT_CODE=1; compose_discard; return; }
    is_pinned_bad "$REPO" "$REMOTE" && { log "SKIP $IMG 为钉住坏版本；为避免重建时带上它，跳过整个项目"; compose_discard; return; }
    LOCID=$(local_imgid_for "$IMG")
    [ "$LOCID" != "MIXED" ] || { log "SKIP 项目内同一镜像 $IMG 的运行版本不一致，请先人工统一"; compose_discard; return; }
    [ -n "$LOCID" ] || { log "SKIP Compose 文件镜像 $IMG 与现有容器不匹配/无回滚基线，请先人工 up"; compose_discard; return; }
    if ! is_current "$LOCID" "$REMOTE"; then
      log "发现新版本 $IMG 远端=$REMOTE 本地=$LOCID"
      echo "$IMG|$LOCID|$REPO|$TAG" >> "$C_MAP"
    else
      log "OK $IMG 已是最新"
    fi
  done
  [ -s "$C_MAP" ] || { log "OK 项目全部镜像已是最新（耗时 $(elapsed)s）"; compose_discard; return; }
  [ "$DRY_RUN" != "1" ] || { log "DRY 有 $(wc -l < "$C_MAP" | tr -d ' ') 个镜像待更新，不执行"; compose_discard; return; }
  [ "$(left)" -gt $((T_UP + T_HEALTH + T_ROLLBACK + 15)) ] || { log "ERR 剩余预算不足，未改动"; EXIT_CODE=1; compose_discard; return; }

  C_PHASE="preup"
  cat > "$C_STATE" <<EOF
COMPOSE_NAME=$COMPOSE_NAME
C_DIR=$C_DIR
C_CFILES=$C_CFILES
C_ENVFILE=$C_ENVFILE
C_MAP=$C_MAP
C_PHASE=$C_PHASE
EOF
  ACTIVE_KIND="compose"
  if ! compose_stage_tags; then
    log "ERR 旧镜像暂存失败，未改动"
    compose_abort_before_up
    EXIT_CODE=1
    return
  fi
  _fail=0
  # 按剩余镜像数分摊拉取预算。关键：预算池必须在**每轮重新计算**——
  # 若只在循环外算一次，靠后的镜像会因为分母变小而拿到更大份额（150s→300s），
  # 前一个镜像耗掉的时间根本没被扣掉，等于没有分摊。
  _n_img=$(wc -l < "$C_MAP" | tr -d ' ')
  case "$_n_img" in ''|*[!0-9]*|0) _n_img=1 ;; esac
  _idx=0
  while IFS='|' read -r _img _old _repo _tag; do
    _idx=$((_idx + 1))
    _rest=$((_n_img - _idx + 1))
    _pool=$(( START + T_HARD - (T_UP + T_HEALTH + T_ROLLBACK + 15) - $(now) ))
    [ "$_pool" -gt 0 ] || _pool=1
    _share=$((_pool / _rest))
    [ "$_share" -lt 20 ] && _share=20        # 别把尾巴切得太碎，留一个可用下限
    _dl=$(( $(now) + _share ))
    # 重试的截止时刻要单独算：重试不能把后面镜像的份额吃掉。
    # 后面还剩 (_rest-1) 个镜像，每个先给它留 20 秒保底。
    _reserve=$(( (_rest - 1) * 20 ))
    _retry_pool=$(( _pool - _share - _reserve ))
    [ "$_retry_pool" -lt 20 ] && _retry_pool=20
    _retry_dl=$(( $(now) + _retry_pool ))
    if ! pull_with_retry "$_repo" "$_tag" "$C_WORK/pull-$(safe_key "$_repo").log" "$_dl" "$_retry_dl"; then
      log "ERR 拉取失败 $_img：$PULL_MSG"; _fail=1; break
    fi
    if [ -n "$PULL_DIGEST" ]; then
      _got=$(docker image inspect "$_img" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
        | grep -F "${_repo}@" | sed 's/^[^@]*@//' | head -n1)
      if [ "$_got" != "$PULL_DIGEST" ]; then
        log "ERR $_img digest(${_got:-空}) 与拉取流($PULL_DIGEST) 不一致"; _fail=1; break
      fi
    fi
  done < "$C_MAP"
  if [ "$_fail" = "1" ]; then
    compose_abort_before_up
    log "ERR 拉取未完成，容器未切换"
    EXIT_CODE=1
    return
  fi

  C_PHASE="postup"
  cat > "$C_STATE" <<EOF
COMPOSE_NAME=$COMPOSE_NAME
C_DIR=$C_DIR
C_CFILES=$C_CFILES
C_ENVFILE=$C_ENVFILE
C_MAP=$C_MAP
C_PHASE=$C_PHASE
EOF
  (cd "$C_DIR" && compose_env && timeout -s KILL "$T_UP" docker compose up -d --force-recreate) || {
    compose_fail_after_up "compose up 失败或超时，可能已有部分服务被重建" || return
    return
  }
  while IFS='|' read -r _img _old _repo _tag; do
    _new=$(docker image inspect -f '{{.Id}}' "$_img" 2>/dev/null)
    [ -n "$_new" ] || { compose_fail_after_up "更新后无法读取新镜像 $_img" || return; return; }
    [ -n "$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_NAME}" --filter "ancestor=$_new" 2>/dev/null)" ] || {
      compose_fail_after_up "没有运行中的容器使用新镜像 $_img" || return; return;
    }
  done < "$C_MAP"
  _reason=$(compose_health)
  if [ $? -ne 0 ]; then compose_fail_after_up "健康门禁：$_reason" || return; return; fi

  while IFS='|' read -r _img _old _repo _tag; do
    if docker tag "$_old" "$_repo:prev" 2>/dev/null; then
      log "回滚点已更新为 $_repo:prev"
    else
      log "WARN 回滚点标签 $_repo:prev 打标失败；本轮更新已成功，但下次失败将无法回滚到这一版"
    fi
    docker rmi "$_repo:rollback-pending" >/dev/null 2>&1 || true
  done < "$C_MAP"
  ACTIVE_KIND=""; rm -f "$C_STATE"
  # 成功收尾：清掉整个事务目录（map / pull.log / 状态），失败与中断路径保留现场。
  rm -rf "$C_WORK" 2>/dev/null || true
  log "OK Compose 项目 $COMPOSE_NAME 更新完成且健康（总耗时 $(elapsed)s）"
}

# ===========================================================================
# 主流程
# ===========================================================================
if [ -n "$COMPOSE_NAME" ] && [ -z "$CONTAINER_NAME" ]; then
  case "$COMPOSE_NAME" in *[!A-Za-z0-9_.-]*) log "ERR Compose 名不合法"; exit 1 ;; esac
  check_deps
  compat_notice "$(compat_state_dir)"
  resolve_compose || exit 1
  [ -n "$C_DIR" ] || {
    log "ERR 找不到 Compose 项目 $COMPOSE_NAME"
    log "    该项目没有运行中的容器可供发现目录，请用 --compose-dir 指定项目目录"
    exit 1
  }
  compose_update
elif [ -z "$COMPOSE_NAME" ] && [ -n "$CONTAINER_NAME" ]; then
  check_deps
  compat_notice "$(compat_state_dir)"
  api_negotiate || exit 1
  plain_update
else
  log "ERR 必须且只能指定一个更新目标"
  log "    当前 COMPOSE_NAME='$COMPOSE_NAME' CONTAINER_NAME='$CONTAINER_NAME'"
  log "    用 --compose <名> 或 --container <名> 指定，或用 --help 查看用法"
  exit 1
fi

if [ "$EXIT_CODE" -ne 2 ]; then
  # --dry-run 承诺「不动任何东西」：连坏版本解除钉住和孤儿镜像清理都要跳过。
  if [ "$DRY_RUN" != "1" ]; then
    for _r in ${P_REPO:-} ${REPO:-} $(_all_repos); do
      [ -n "$_r" ] || continue
      expire_bad "$_r"; clean_orphans "$_r"
    done
  fi
fi
log "本轮结束，总耗时 $(elapsed)s"
exit "$EXIT_CODE"