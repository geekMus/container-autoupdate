#!/bin/sh
# ============================================================================
# container-autoupdate 引导器（bootstrap）
#
# 解决的问题：让定时任务不必「每轮都联网下载脚本」。
#   固定版本（CT_VERSION=0.3.2）：本地有就直接跑，完全不联网。
#   latest（默认）           ：先探测远端 tag；本地同版本则直接复用，不同才下载并缓存。
#
# 用法（放进 DPanel 计划任务 / cron）：
#   sh -c 'curl -fsSL <本文件地址> | sh -s -- --compose myapp'
# 或者把本文件落地一次，之后定时任务直接跑本地文件（更快、更稳）：
#   /usr/local/bin/ct-bootstrap.sh --compose myapp
#
# 设计取舍：
#   - 探测用 HTTP HEAD 读 302 的 Location 里的 tag：只取响应头，几乎零流量。
#     探测失败**不阻断**：本地有缓存就继续用，只打 WARN。
#   - 下载必须落地到临时文件再执行。管道写法（curl | sh）会把下载失败吞成 rc=0。
#   - 缓存按版本分文件，只保留最近 CACHE_KEEP 个。
#   - 下载后要真正校验（语法 + 版本号 + 特征字符串），否则半截文件会被当脚本跑。
# ============================================================================

BOOT_VERSION="1"

REPO="geekMus/container-autoupdate"
ASSET="container-autoupdate.sh"

# ---- 可覆盖的配置 ----
CACHE_DIR="${CT_CACHE_DIR:-/var/cache/container-autoupdate}"
PIN_VERSION="${CT_VERSION:-}"     # 非空 = 固定版本模式（如 0.3.2 或 v0.3.2）
SOURCE="${CT_SOURCE:-auto}"       # auto | direct | gh-proxy | ghproxy | 自定义前缀
CACHE_KEEP="${CT_CACHE_KEEP:-3}"  # 保留几个历史版本
T_NET="${CT_T_NET:-20}"           # 单次网络超时（秒）
TRIES="${CT_TRIES:-2}"            # 每个源尝试次数
FORCE_UPDATE="${CT_FORCE:-0}"     # 1 = 忽略缓存强制重新下载
QUIET="${CT_QUIET:-0}"

log() { [ "$QUIET" = "1" ] || echo "[ct-bootstrap] $*" >&2; }
die() { echo "[ct-bootstrap] ERR $*" >&2; exit 1; }

# ---- 候选源基址（每行一个，按优先级）----
# 实测（N1 dpanel 容器内，2026-11-01）：
#   gh-proxy.com  ：Range 4KB 1~2s，完整下载 64KB 1s，稳定
#   github.com    ：直连不稳（偶发 DNS rc=6），HEAD 要 12s，Range 偶发失败
#   ghproxy.net   ：连续 3 次 15s 超时，已不可用
# 所以默认顺序是 gh-proxy 优先、直连兜底。
base_urls() {
  case "$SOURCE" in
    direct)   echo "https://github.com/$REPO" ;;
    gh-proxy) echo "https://gh-proxy.com/https://github.com/$REPO" ;;
    ghproxy)  echo "https://ghproxy.net/https://github.com/$REPO" ;;
    auto)
      echo "https://gh-proxy.com/https://github.com/$REPO"
      echo "https://github.com/$REPO"
      echo "https://ghproxy.net/https://github.com/$REPO"
      ;;
    *)        echo "$SOURCE" ;;
  esac
}

# ---- 基址 + tag → 完整下载地址；tag 为空表示 latest ----
url_for() {
  _base="$1"; _tag="$2"
  if [ -n "$_tag" ]; then
    echo "$_base/releases/download/$_tag/$ASSET"
  else
    echo "$_base/releases/latest/download/$ASSET"
  fi
}

# ---- 从脚本文件读 VERSION（注意 BRE 里捕获组要写 \( \)）----
file_version() {
  [ -f "$1" ] || return 1
  _fv=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1)
  [ -n "$_fv" ] || return 1
  echo "$_fv"
}

# ---- 校验一个文件确实是我们的脚本 ----
verify_file() {
  _vf="$1"
  [ -s "$_vf" ] || return 1
  _vs=$(wc -c < "$_vf" 2>/dev/null || echo 0)
  [ "$_vs" -gt 1000 ] || return 1
  # 语法必须合法（半截文件通常在这里挂）
  sh -n "$_vf" 2>/dev/null || return 1
  # 必须有可解析的 VERSION
  file_version "$_vf" >/dev/null 2>&1 || return 1
  # 必须有特征字符串，挡住「语法恰好合法但内容无关」的文件
  grep -q 'container-autoupdate' "$_vf" 2>/dev/null || return 1
  return 0
}

# ---- 探测 latest 版本 ----
# 实测结论（2026-11-01，N1 dpanel 容器内）：
#   - HEAD 读 302 Location：只有直连 github.com 能给 Location，但要 12 秒，太慢；
#     代理（gh-proxy）对 HEAD 不返回 Location，拿不到 tag。
#   - Range 0-4000 + 读文件里的 VERSION：代理上稳定 1~2 秒，且拿到的是**真实版本号**，
#     比解析 URL 更可信。所以统一用 Range。
#   - 完整下载只要 1 秒（64KB），所以探测的价值不在省时间，而在「本地同版本就不下载」。
# 返回：把版本号（如 0.3.2，不含 v）打到 stdout；全部失败返回非 0。
probe_latest_version() {
  for _pb in $(base_urls); do
    _pu=$(url_for "$_pb" "")
    _ptry=1
    while [ "$_ptry" -le "$TRIES" ]; do
      _ppart=$(curl -fsSL --max-time "$T_NET" -r 0-4000 "$_pu" 2>/dev/null)
      if [ -n "$_ppart" ]; then
        _pv=$(printf '%s\n' "$_ppart" | sed -n 's/^VERSION="\([^"]*\)".*/\1/p' | head -n1)
        if [ -n "$_pv" ]; then
          echo "$_pv"
          return 0
        fi
      fi
      _ptry=$((_ptry + 1))
    done
  done
  return 1
}

# ---- 下载并校验 ----
download() {
  _dtag="$1"; _ddst="$2"
  for _db in $(base_urls); do
    _du=$(url_for "$_db" "$_dtag")
    _dtry=1
    while [ "$_dtry" -le "$TRIES" ]; do
      log "下载 $_du（第 $_dtry 次）"
      _dtmp="$_ddst.tmp.$$"
      rm -f "$_dtmp"
      if curl -fsSL --max-time "$((T_NET * 3))" "$_du" -o "$_dtmp" 2>/dev/null \
         && verify_file "$_dtmp"; then
        mv "$_dtmp" "$_ddst" || { rm -f "$_dtmp"; continue; }
        chmod +x "$_ddst" 2>/dev/null || true
        return 0
      fi
      rm -f "$_dtmp"
      _dtry=$((_dtry + 1))
    done
  done
  return 1
}

# ---- 只保留最近 N 个缓存 ----
prune_cache() {
  [ "$CACHE_KEEP" -gt 0 ] 2>/dev/null || return 0
  _pn=0
  for _pf in $(ls -1t "$CACHE_DIR"/"$ASSET".v* 2>/dev/null); do
    _pn=$((_pn + 1))
    [ "$_pn" -gt "$CACHE_KEEP" ] && rm -f "$_pf"
  done
}

# ---- 主流程 ----
mkdir -p "$CACHE_DIR" 2>/dev/null || die "无法创建缓存目录 $CACHE_DIR"

# 目标版本：纯版本号（如 0.3.2），不含 v
TARGET_VER=""
if [ -n "$PIN_VERSION" ]; then
  case "$PIN_VERSION" in v*) TARGET_VER="${PIN_VERSION#v}" ;; *) TARGET_VER="$PIN_VERSION" ;; esac
  log "固定版本模式：$TARGET_VER"
else
  if TARGET_VER=$(probe_latest_version); then
    log "远端 latest = $TARGET_VER"
  else
    TARGET_VER=""
    log "WARN 探测远端版本失败（网络问题），回退到本地缓存"
  fi
fi

CACHE_FILE=""
if [ -n "$TARGET_VER" ]; then
  CACHE_FILE="$CACHE_DIR/$ASSET.v$TARGET_VER"
  # 已有但坏了，删掉重下
  if [ -f "$CACHE_FILE" ] && [ "$FORCE_UPDATE" != "1" ] && ! verify_file "$CACHE_FILE"; then
    log "WARN 本地缓存文件损坏，将重新下载"
    rm -f "$CACHE_FILE"
  fi
else
  # 探测失败：用最新的、且通过校验的缓存
  for _cf in $(ls -1t "$CACHE_DIR"/"$ASSET".v* 2>/dev/null); do
    if verify_file "$_cf"; then CACHE_FILE="$_cf"; break; fi
  done
  [ -n "$CACHE_FILE" ] || die "探测远端版本失败，且本地无可用缓存。请先联网跑一次。"
  log "使用本地缓存：$CACHE_FILE"
fi

if [ "$FORCE_UPDATE" = "1" ] || [ ! -f "$CACHE_FILE" ]; then
  [ -n "$TARGET_VER" ] || die "无法下载：不知道目标版本"
  download "v$TARGET_VER" "$CACHE_FILE" || die "下载失败（所有源都试过了）：v$TARGET_VER"
  log "已缓存 $CACHE_FILE（版本 $(file_version "$CACHE_FILE")）"
else
  log "本地已有 $(file_version "$CACHE_FILE")（$CACHE_FILE），跳过下载"
fi

prune_cache

# 参数原样透传
exec sh "$CACHE_FILE" "$@"
