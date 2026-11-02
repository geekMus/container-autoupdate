#!/bin/sh
# ============================================================================
# ct-stale-lock-check.sh —— 排查「上一轮没退干净」留下的进程与垃圾
#
# 本脚本**只读**：不改任何东西、不杀任何进程、不删任何文件。
# 只把问题列出来，末尾给出可复制的清理命令，由你确认后手动执行。
#
# 它查三样东西：
#   1) 旧的互斥锁文件（较新的版本已不再使用锁，这些文件只是残留垃圾）
#   2) 谁正开着这些锁文件（残留的子进程）
#   3) 残留的镜像拉取进程（会一直占着网络与磁盘）
# 外加：状态目录里残留的事务目录（哪些能删、哪些必须留）
#
# 用法：
#   sh ct-stale-lock-check.sh
# 可选环境变量：
#   CT_LOCK_PREFIX   锁文件前缀（默认 /tmp/.container-autoupdate）
#   CT_STATE_ROOT    状态目录（默认 /tmp/.container-autoupdate）
#
# 兼容性：只用 POSIX sh + busybox 基础命令（awk/sed/grep/readlink/tr）。
# ============================================================================

LOCK_PREFIX="${CT_LOCK_PREFIX:-/tmp/.container-autoupdate}"
STATE_ROOT="${CT_STATE_ROOT:-/tmp/.container-autoupdate}"
SELF=$$
SELFPPID=$PPID

echo "=== 0) 环境 ==="
echo "  锁前缀   $LOCK_PREFIX"
echo "  状态目录 $STATE_ROOT"
echo "  本脚本 PID=$SELF"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# 从 /proc/<pid>/stat 里取 PPid。
# 不能按空白切分后找 ')'：comm 字段可能带空格甚至括号。
# 正确做法是找到**最后一个** ')'，它后面的第 2 个字段才是 PPid。
_proc_ppid() {
  _d="$1"
  _pp=$(awk '/^PPid:/ { print $2; exit }' "$_d/status" 2>/dev/null)
  [ -n "$_pp" ] || _pp=$(awk '{ n=0; for (i=1;i<=length($0);i++) if (substr($0,i,1)==")") n=i; if (n>0) { r=substr($0,n+2); split(r,a," "); print a[2]; exit } }' "$_d/stat" 2>/dev/null)
  echo "${_pp:-?}"
}

_proc_cmd() {
  tr '\0' ' ' < "$1/cmdline" 2>/dev/null
}

# 是不是「我们自己」？排查脚本自己也持有锁文件打开句柄时会被自己扫到，
# 不排除掉就会报出「占锁者 = 排查脚本自己」这种假警报。
_is_self() {
  _p="$1"
  [ "$_p" = "$SELF" ] && return 0
  [ "$_p" = "$SELFPPID" ] && return 0
  _c=$(_proc_cmd "/proc/$_p")
  case "$_c" in
    *ct-stale-lock-check*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
echo
echo "=== 1) 锁文件 ==="
_lockfiles=$(ls -1 "${LOCK_PREFIX}"*.lock 2>/dev/null)
if [ -n "$_lockfiles" ]; then
  for _f in $_lockfiles; do
    _sz=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
    _mt=$(stat -c %y "$_f" 2>/dev/null || stat -c %Y "$_f" 2>/dev/null || echo '?')
    echo "  $_f  (${_sz:-?} 字节, 修改时间 ${_mt})"
  done
  echo "  → 这些是旧版本的互斥锁文件。当前版本已不再使用锁，它们只是残留垃圾。"
else
  echo "  没有锁文件（说明当前跑的版本已不使用互斥锁）"
fi

# ---------------------------------------------------------------------------
echo
echo "=== 2) 谁正开着这些锁文件 ==="
_n=0
for _d in /proc/[0-9]*; do
  [ -d "$_d/fd" ] || continue
  _pid="${_d#/proc/}"
  _is_self "$_pid" && continue
  for _fd in "$_d"/fd/*; do
    [ -e "$_fd" ] || continue
    _tgt=$(readlink "$_fd" 2>/dev/null)
    case "$_tgt" in
      "${LOCK_PREFIX}"*.lock*|"${LOCK_PREFIX}"*.lock*\(deleted\))
        _n=$(( _n + 1 ))
        _ppid=$(_proc_ppid "$_d")
        _cmd=$(_proc_cmd "$_d")
        echo "  PID=$_pid  PPID=$_ppid  fd=${_fd##*/} -> $_tgt"
        echo "      命令：${_cmd:-（无法读取）}"
        ;;
    esac
  done
done
if [ "$_n" -eq 0 ]; then
  echo "  没有任何进程占着锁文件"
else
  echo "  → 上面这些进程是上一轮没退干净的残留。它们会一直占着锁，"
  echo "    让之后每一轮都跳过（SKIP 同一更新目标的另一个任务仍在执行）。"
fi

# ---------------------------------------------------------------------------
echo
echo "=== 3) 残留的镜像拉取进程 ==="
_m=0
for _d in /proc/[0-9]*; do
  _pid="${_d#/proc/}"
  _is_self "$_pid" && continue
  _cmd=$(_proc_cmd "$_d")
  case "$_cmd" in
    *images/create*)
      _m=$(( _m + 1 ))
      echo "  PID=$_pid  PPID=$(_proc_ppid "$_d")  ${_cmd}"
      ;;
  esac
done
if [ "$_m" -eq 0 ]; then
  echo "  没有残留的拉取进程"
else
  echo "  → 这些是拉取镜像的残留进程，会一直占网络和磁盘。"
fi

# ---------------------------------------------------------------------------
echo
echo "=== 4) 状态目录里的残留 ==="
if [ -d "$STATE_ROOT" ]; then
  for _d in "$STATE_ROOT"/*; do
    [ -e "$_d" ] || continue
    _bn=$(basename "$_d")
    case "$_bn" in
      compat)
        echo "  $_d/  ← 跨版本提示用的记录（记着每个目标上次跑过的版本）"
        echo "      删掉不影响功能，只是升级时会再提示一次。保留即可。"
        ;;
      *)
        echo "  $_d/  ← 事务目录（某轮更新的现场）"
        echo "      正常收尾的轮次会自动删掉；还留在这里说明那一轮出过问题。"
        echo "      先看里面的日志确认问题已解决，确认无用再删。"
        ;;
    esac
  done
else
  echo "  状态目录不存在（$STATE_ROOT）"
fi

# ---------------------------------------------------------------------------
echo
echo "=== 5) 怎么清理（看完上面的清单，确认没人要了再执行） ==="
echo "  a) 删掉没用的旧锁文件（当前版本已不使用锁，留着只是垃圾）："
echo "       rm -f ${LOCK_PREFIX}.*.lock"
echo "  b) 杀掉上面列出的残留进程（把 PID 换成实际值）："
echo "       kill <PID>"
echo "     确认它真的该杀再看："
echo "       cat /proc/<PID>/cmdline | tr '\\0' ' '"
echo "  c) 删掉确认无用的事务目录："
echo "       rm -rf ${STATE_ROOT}/<事务目录名>"
echo "  d) 升级到不再使用互斥锁的版本，让这个问题不再复发；"
echo "     同时确认启动命令里没有残留的 LOCK_PREFIX=..."
echo "     （有的话脚本会按破坏性变更中止，退出码 3）。"
echo
echo "  本脚本只读，没有改动任何东西。"
