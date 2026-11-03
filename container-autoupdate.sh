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
# 安全原则：
#   · 容器分支不写 Docker：变更动作只有 DPanel 一个执行者。
#     Compose 分支只用 compose 自己的 pull / up -d，不手工 tag、不手工 create、不删任何东西。
#   · 失败原因同时落到真正的 stderr（计划任务失败时只收 stderr、丢弃 stdout）。
#   · 只检查不动手：--dry-run。
#   · 破坏性变更（参数 / 环境变量 / 行为）登记在 BREAKING_TABLE，脚本会主动
#     识别旧写法并给出迁移说明，而不是静默忽略。
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
COMPAT_ROOT="${COMPAT_ROOT:-/tmp/.container-autoupdate/compat}"  # 跨版本提示的记录目录
COMPAT_UNTIL="${COMPAT_UNTIL:-}"   # --compat：用户声明「我只验证到这个版本」

START=$(date +%s)
VERSION="2.1.0"
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
BREAKING_TABLE='
1.0.0|env|LOCK_PREFIX|删除这个环境变量|1.0.0 起脚本不再使用互斥锁，并发由 DPanel 计划任务保证
1.0.0|behavior|同一更新目标由脚本内的互斥锁串行|同一目标只挂一个 DPanel 计划任务|1.0.0 起移除脚本内的互斥锁：v0.4.0 的锁会被残留的子进程长期占住，导致之后每一轮都跳过
2.0.0|behavior|脚本自己拉镜像、自己重建容器 / Compose 项目（自带健康门禁与 :prev 回滚点）|容器走 DPanel 的 container:upgrade，Compose 项目走 DPanel 的 compose:deploy|2.0.0 起更新动作全部交给 DPanel：脚本只负责检查与转交，回滚交给 DPanel 的备份容器（<容器名>-bak-<时间戳>）
2.0.0|flag|--state-dir|删除这个参数|2.0.0 起脚本不再维护状态目录；跨版本提示记录改到 COMPAT_ROOT
2.0.0|flag|--bad-ttl-days|删除这个参数|2.0.0 起不再有「坏版本钉住」，回滚由 DPanel 负责
2.0.0|flag|--pull-retries|删除这个参数|2.0.0 起拉取不再由脚本负责（容器模式交给 DPanel，Compose 模式交给 docker compose），脚本不再管理拉取与重试
2.0.0|env|STATE_ROOT|删除这个环境变量|2.0.0 起脚本不再维护状态目录；跨版本提示记录改到 COMPAT_ROOT（默认 /tmp/.container-autoupdate/compat）
2.0.0|env|BAD_TTL_DAYS|删除这个环境变量|2.0.0 起不再有「坏版本钉住」与 TTL，回滚由 DPanel 负责
2.0.0|env|PULL_RETRIES|删除这个环境变量|2.0.0 起拉取不再由脚本负责（容器模式交给 DPanel，Compose 模式交给 docker compose），脚本不再管理拉取与重试
2.0.0|env|DIGEST_RETRIES|删除这个环境变量|2.0.0 起「有没有新版本」不再由脚本查 digest：容器模式看 DPanel 的 upgrade，Compose 模式看 docker compose pull 拉到了什么
2.0.0|env|DIGEST_RETRY_WAIT|删除这个环境变量|同上：不再由脚本查询远端 digest
2.0.0|env|T_STALL|删除这个环境变量|2.0.0 起脚本不再读 Docker 拉取流，拉取停滞判定取消
2.0.0|env|T_STALL_FINISH|删除这个环境变量|同上：拉取收尾由更新执行者（DPanel / docker compose）自行处理
2.0.0|env|T_PULL_MAX|删除这个环境变量|拉取交给更新执行者；脚本侧可用 DP_T_PULL / DP_T_UPGRADE 限制单次调用的时长
2.0.0|env|T_UP|删除这个环境变量|容器重建由 DPanel 完成（DP_T_UPGRADE 控制脚本等待多久）；Compose 侧用 DP_T_UP
2.0.0|env|T_HEALTH|删除这个环境变量|健康观察由 DPanel 的升级流程负责
2.0.0|env|HEALTH_TRIES|删除这个环境变量|健康门禁已移除，由 DPanel 负责
2.0.0|env|T_ROLLBACK|删除这个环境变量|回滚由 DPanel 的备份机制负责
2.0.0|env|PLAIN_BOOT|删除这个环境变量|无 healthcheck 容器的观察已交由 DPanel
2.0.0|env|COMPOSE_BASE|删除这个环境变量|不再需要从容器标签反查 Compose 目录的基路径（反查用 compose 自己写在容器上的标签）
2.1.0|behavior|Compose 更新交给 DPanel 的 compose:deploy|Compose 项目改用 docker compose pull + up -d 就地重新部署|2.1.0 起 Compose 模式不再依赖 DPanel 的 compose:deploy：不需要项目先在 DPanel 里登记，也不用管 --pull-image；容器模式仍然交给 DPanel
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
    # 「删除这个参数」是一个特殊的新写法：表示没有替代写法。
    # 这时不要打印「把 X 换成 删除这个参数」那种绕口的句子。
    if [ "$_n" = "删除这个参数" ]; then
      log "    从 v$_v 起：$1 已移除"
      log "    原因：$_d"
      log "    迁移方式：删掉 $1 即可，不需要任何替代设置"
    else
      log "    从 v$_v 起改为：$_n"
      log "    原因：$_d"
      log "    迁移方式：把 $1 换成 $_n"
    fi
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
  return 0
}

# 记录「这个目标已经见过当前版本」：下次同版本不再重复提示。
# 与 compat_notice 分开是刻意的：提示要早（依赖检查之前就要打印，否则会被
# 「找不到 docker / DPanel CLI」盖掉），记录要晚（只有真跑起来的轮次才算
# 用户已经知悉；依赖缺失时不该把提示永久吞掉）。
compat_record() {
  _dir="$1"
  [ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null || return 0
  printf '%s\n' "$VERSION" > "$_dir/lastver" 2>/dev/null || true
  return 0
}

# 每个目标一个记录目录，用于「跨版本提示」。
compat_state_dir() {
  if [ -n "$COMPOSE_NAME" ] && [ -z "$CONTAINER_NAME" ]; then
    printf '%s/compose-%s' "$COMPAT_ROOT" "$(safe_key "$COMPOSE_NAME")"
  elif [ -z "$COMPOSE_NAME" ] && [ -n "$CONTAINER_NAME" ]; then
    printf '%s/container-%s' "$COMPAT_ROOT" "$(safe_key "$CONTAINER_NAME")"
  else
    printf '%s' "$COMPAT_ROOT"
  fi
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
  --compat <版本>        声明只验证到某个版本；脚本若含更新的破坏性变更就中止
  -h, --help             显示本帮助
  -V, --version          显示版本

环境变量：
  UPD_COMPOSE / UPD_CONTAINER   目标（同命令行）
  DOCKER_SOCK / DOCKER_HOST     docker CLI 的连接端点
  COMPOSE_DIR                   Compose 项目目录（同 --compose-dir）
  DPANEL_NAME                   DPanel 容器名（默认 dpanel）
  DPANEL_BIN                    DPanel CLI 路径（默认 /app/server/dpanel）
  DPANEL_DOCKER_ENV             DPanel 里的 docker 环境名（默认 local）
  COMPAT_ROOT                   跨版本提示记录目录（默认 /tmp/.container-autoupdate/compat）
  DRY_RUN=1                     同 --dry-run
  COMPAT_UNTIL                  同 --compat
  T_HARD                        整轮时间硬上限（秒，默认 540）
  T_INSPECT / DP_T_CHECK        单次「检查」调用超时（秒，默认 120）
  DP_T_UPGRADE                  单次容器升级调用超时（秒，默认 420）
  DP_T_PULL / DP_T_UP           Compose 模式的 pull / up -d 超时（秒，默认 420 / 180）
  DP_MIN_UPGRADE                剩余预算低于这个值就不动手（秒，默认 90）

退出码：
  0  成功，或无需更新，或按规则跳过
  1  配置/环境错误，或本轮未能完成更新（目标保持原样）
  2  保留（v2.0.0 起不再出现：容器回滚由 DPanel 负责；Compose 就地重新部署，
     失败时脚本不部署，不会留下半新半旧的项目）
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

  # 先看一眼有没有新版本，不动手
  container-autoupdate.sh --container myapp --dry-run

  # Compose 项目的目录通常是自动认出来的；要显式指定也可以：
  container-autoupdate.sh --compose myapp --compose-dir /opt/myapp

  # 直接跑远程脚本，跟随最新发布版（地址不含版本号，粘贴即用）
  # 先落地再执行：`curl ... | sh` 会把下载失败的退出码吞掉，出问题时看不到原因。
  _t=$(mktemp)
  curl -fsSL -L https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh -o "$_t" \
    && sh "$_t" --compose myapp
  rm -f "$_t"

  # 生产环境想锁死版本：把上面的 latest/download 换成带版本号的路径
  # releases/download/v2.1.0/container-autoupdate.sh
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
}

# ---------- 与 DPanel 打交道 ----------
# 两种运行方式，效果完全一样（同一个二进制、同一份 config、同一个 docker socket）：
#   1) 脚本本来就在 DPanel 容器里（计划任务的常见情形）→ 直接执行二进制；
#   2) 脚本在别的容器 / 宿主上 → docker exec 进 DPanel 容器执行。
DP_IN_CONTAINER=0
[ -x "$DPANEL_BIN" ] && DP_IN_CONTAINER=1

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
# `compose:deploy` 对未登记的项目会返回 rc=0 但 JSON 是 {"code":500,...}（实测）。
# 真机实测到的形状（DPanel 1.11.2）：
#   成功 —— 容器检查 {"upgrade":..,"status":"latest"|"upgrade"}；
#           容器升级 {"containerId":"..."}；
#           Compose 部署 {"name":"项目名"} —— 注意成功时**没有 code 字段**；
#   失败 —— {"code":500,"error":"url: /dpanel/api/..."}。
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
    log "WARN 剩余时间不足（${_rest}s < ${DP_MIN_UPGRADE}s），本轮不启动升级，容器保持原样"
    log "     下一轮计划任务会重新检查；也可以把 T_HARD 或计划任务的超时调大"
    EXIT_CODE=1
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

# 镜像 id 取短一点，日志里好读
_short_id() { printf '%s' "$1" | sed 's/^sha256://' | awk '{print substr($0,1,12)}'; }

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
    log "WARN 剩余时间不足（${_rest}s < ${DP_MIN_UPGRADE}s），本轮不部署，项目保持原样"
    EXIT_CODE=1
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
  log "    运行状态：$_run/$_tot"
  return 0
}

# ---------- 主流程 ----------
parse_args "$@"

# --docker-sock 仍然认：以前它是给 docker API 用的，现在只用来指定 docker CLI 的端点。
if [ -n "$DOCKER_SOCK" ]; then
  export DOCKER_HOST="unix://$DOCKER_SOCK"
fi

# 每次真实运行都在日志里留一行版本号：排查历史问题时，能立刻看出那一轮
# 跑的是哪一版脚本（升级过 latest 之后尤其重要）。
log "container-autoupdate v$VERSION 启动"

# 破坏性变更防线（顺序很重要）：
#   1. 旧环境变量还在设 → 说明用户仍按旧文档调用，立刻中止并给出新写法
#   2. --compat 声明的版本比脚本旧、且中间有 behavior 级变更 → 中止
# 这两步必须放在 check_deps 之前：调用方式已经失效时，要给出迁移说明，
# 而不是先抱怨「找不到 docker / 找不到 DPanel CLI」——那会把用户引向
# 完全无关的排查方向。
compat_removed_env
compat_gate

# 目标判定（供跨版本提示与后面的分支共用）
_GOAL=""
if [ -n "$COMPOSE_NAME" ] && [ -z "$CONTAINER_NAME" ]; then
  _GOAL="compose"
elif [ -z "$COMPOSE_NAME" ] && [ -n "$CONTAINER_NAME" ]; then
  _GOAL="container"
fi

# 跨版本提示放在这里：它说的是「你的调用方式可能受影响」，
# 不该被一句「找不到 docker / DPanel CLI」盖过去。
if [ -n "$_GOAL" ]; then
  compat_notice "$(compat_state_dir)"
fi

check_deps

# 依赖齐了才记录 lastver：这一轮真的会跑到更新逻辑，用户已经看到提示了。
if [ -n "$_GOAL" ]; then
  compat_record "$(compat_state_dir)"
fi

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
