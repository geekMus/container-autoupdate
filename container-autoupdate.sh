#!/bin/sh
# ===========================================================================
# 通用容器自动更新 v0.1.0 —— 单轮逻辑，可放进任意定时器（cron / systemd timer /
# DPanel 计划任务 / CI）。脚本本身不含更新频率逻辑。
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
#   · 拉取只 kill 本轮 curl PID；互斥锁按「更新目标」隔离（不同目标可并行，同一目标串行）；
#     坏版本按钉住时间计算 TTL。
#
# 注意：容器回滚只能恢复容器与镜像，不能撤销新程序已经做过的数据迁移。
# 生产数据库仍应另有备份。私有仓库需要匿名 API 拉取可用，否则安全中止。
# ===========================================================================
set -u
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
API_VERSION="1.47"
API="http://localhost/v1.47"
LOCK_PREFIX="${LOCK_PREFIX:-/tmp/.container-autoupdate}" # 互斥锁前缀，实际文件名按更新目标派生
STATE_ROOT="${STATE_ROOT:-/tmp/.container-autoupdate}"
BAD_TTL_DAYS="${BAD_TTL_DAYS:-7}"

START=$(date +%s)
VERSION="0.1.0"
T_HARD="${T_HARD:-540}"
T_INSPECT="${T_INSPECT:-30}"
T_STALL="${T_STALL:-60}"
T_PULL_MAX="${T_PULL_MAX:-300}"
T_UP="${T_UP:-60}"
T_HEALTH="${T_HEALTH:-120}"
HEALTH_TRIES="${HEALTH_TRIES:-12}"
T_ROLLBACK="${T_ROLLBACK:-60}"
PLAIN_BOOT="${PLAIN_BOOT:-30}"
DRY_RUN="${DRY_RUN:-0}"
EXIT_CODE=0
ACTIVE_KIND=""
PULL_DIGEST=""
PULL_MSG=""

now()     { date +%s; }
elapsed() { echo $(( $(now) - START )); }
left()    { echo $(( T_HARD - $(elapsed) )); }
log()     { echo "[$(date '+%F %T')] $*"; }
safe_key() { printf '%s' "$1" | sed 's|[^A-Za-z0-9_.-]|_|g'; }
json_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's|\\|\\\\|g; s|"|\\"|g')"; }

usage() {
  cat <<'USAGE'
通用容器自动更新脚本

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
  --state-dir <目录>     事务状态目录（默认 /tmp/.container-autoupdate）
  -h, --help             显示本帮助
  -V, --version          显示版本

环境变量：
  UPD_COMPOSE / UPD_CONTAINER   目标（同命令行）
  COMPOSE_DIR                   同 --compose-dir
  DOCKER_SOCK                   同 --docker-sock
  DOCKER_HOST                   支持 unix:///path 与 tcp://host:port
  DRY_RUN=1                     同 --dry-run
  BAD_TTL_DAYS                  同 --bad-ttl-days
  T_HARD / T_STALL / T_PULL_MAX / T_UP / T_HEALTH / T_ROLLBACK
                                各阶段超时（秒），一般不用改

退出码：
  0  成功，或无需更新，或按规则跳过
  1  配置/环境错误，或本轮未能完成更新（容器保持原样）
  2  回滚本身失败，需要人工介入（现场保留在 --state-dir）

示例：
  # cron 每小时检查一次
  0 * * * * /usr/local/bin/container-autoupdate.sh --compose myapp >> /var/log/ct-update.log 2>&1

  # 直接跑远程脚本（固定 tag，避免上游改动直接影响你的生产）
  curl -fsSL https://raw.githubusercontent.com/geekMus/container-autoupdate/v0.1.0/container-autoupdate.sh \
    | sh -s -- --compose myapp
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --compose)      [ "$#" -ge 2 ] || { echo "ERR --compose 缺少参数" >&2; exit 1; }
                      COMPOSE_NAME="$2"; CONTAINER_NAME=""; shift 2 ;;
      --container)    [ "$#" -ge 2 ] || { echo "ERR --container 缺少参数" >&2; exit 1; }
                      CONTAINER_NAME="$2"; COMPOSE_NAME=""; shift 2 ;;
      --compose-dir)  [ "$#" -ge 2 ] || { echo "ERR --compose-dir 缺少参数" >&2; exit 1; }
                      COMPOSE_DIR="$2"; shift 2 ;;
      --docker-sock)  [ "$#" -ge 2 ] || { echo "ERR --docker-sock 缺少参数" >&2; exit 1; }
                      DOCKER_SOCK="$2"; shift 2 ;;
      --state-dir)    [ "$#" -ge 2 ] || { echo "ERR --state-dir 缺少参数" >&2; exit 1; }
                      STATE_ROOT="$2"; shift 2 ;;
      --bad-ttl-days) [ "$#" -ge 2 ] || { echo "ERR --bad-ttl-days 缺少参数" >&2; exit 1; }
                      BAD_TTL_DAYS="$2"; shift 2 ;;
      --dry-run)      DRY_RUN=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      -V|--version)   echo "$VERSION"; exit 0 ;;
      *)              echo "ERR 未知参数：$1（用 --help 查看用法）" >&2; exit 1 ;;
    esac
  done
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
  for _b in docker curl flock timeout sed awk grep; do
    command -v "$_b" >/dev/null 2>&1 || _missing="$_missing $_b"
  done
  if [ -n "$_missing" ]; then
    echo "ERR 缺少依赖命令：$_missing" >&2
    echo "    需要 docker / curl / flock / timeout 以及 busybox 或 coreutils 基础工具" >&2
    exit 1
  fi
  if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    echo "ERR 无法连接 Docker（socket=${SOCK:-$API_HOST}）" >&2
    echo "    请确认 Docker 正在运行，且当前用户有权限访问 socket" >&2
    exit 1
  fi
}

parse_args "$@"
resolve_docker_endpoint
mkdir -p "$STATE_ROOT"

# 互斥锁按更新目标派生：不同目标各用一把锁（可并行），同一目标才串行。
acquire_lock() {
  if [ -n "$COMPOSE_NAME" ] && [ -z "$CONTAINER_NAME" ]; then
    _lt="compose-$(safe_key "$COMPOSE_NAME")"
  else
    _lt="container-$(safe_key "$CONTAINER_NAME")"
  fi
  LOCK="${LOCK_PREFIX}.${_lt}.lock"
  exec 9>"$LOCK"
  if ! flock -n 9; then
    log "SKIP 同一更新目标（$_lt）的另一个任务仍在执行，本轮跳过"
    exit 0
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
  _repo="$1"; _n=0
  for _id in $(docker images -f dangling=true -q --filter "reference=$_repo" 2>/dev/null | sort -u); do
    [ -n "$(docker ps -a -q --filter ancestor="$_id" 2>/dev/null)" ] && continue
    docker rmi "$_id" >/dev/null 2>&1 && _n=$((_n + 1))
  done
  [ "$_n" -gt 0 ] && log "清理孤儿镜像 $_n 个（$_repo）"
  return 0
}

# ---------- Docker API 版本 ----------
api_negotiate() {
  _v=$(dcurl -s --max-time 10 "$API_HOST/version" 2>/dev/null \
       | sed -n 's/.*"ApiVersion":"\([0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' | head -n1)
  [ -n "$_v" ] || _v="1.47"
  API_VERSION="$_v"
  API="$API_HOST/v${_v}"
  _maj=${_v%%.*}; _min=${_v#*.}
  if [ "$_maj" -lt 2 ] && [ "$_min" -lt 47 ]; then
    log "ERR 容器安全重建需要 Docker API >= 1.47，当前=$_v"
    return 1
  fi
  return 0
}

# ---------- 拉取：只管理本轮 PID ----------
pull_stream() {
  _repo="$1"; _tag="$2"; _log="$3"
  PULL_DIGEST=""; PULL_MSG=""
  _enc=$(printf '%s' "$_repo" | sed 's|/|%2F|g')
  : > "$_log"
  dcurl -sN -X POST \
    "$API/images/create?fromImage=${_enc}&tag=${_tag}" >> "$_log" 2>&1 &
  _pid=$!
  _seen=0; _seen_at=$(now)
  _cap=$(( $(now) + T_PULL_MAX ))
  _hard=$(( START + T_HARD - (T_UP + T_HEALTH + T_ROLLBACK + 15) ))
  [ "$_hard" -lt "$_cap" ] && _cap=$_hard
  while kill -0 "$_pid" 2>/dev/null; do
    sleep 5
    _t=$(now); _sz=$(wc -c < "$_log" 2>/dev/null | tr -d ' ')
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    if [ "$_sz" -gt "$_seen" ]; then _seen=$_sz; _seen_at=$_t; fi
    _idle=$((_t - _seen_at))
    if [ "$_idle" -ge "$T_STALL" ]; then
      kill -9 "$_pid" 2>/dev/null || true; wait "$_pid" 2>/dev/null || true
      PULL_MSG="进度停滞 ${_idle}s（共收 ${_seen} 字节后无新增）"
      return 1
    fi
    if [ "$_t" -ge "$_cap" ]; then
      kill -9 "$_pid" 2>/dev/null || true; wait "$_pid" 2>/dev/null || true
      PULL_MSG="达到拉取上限（共收 ${_seen} 字节）"
      return 1
    fi
  done
  wait "$_pid" 2>/dev/null
  _rc=$?
  if [ "$_rc" -ne 0 ]; then PULL_MSG="拉取流退出 rc=$_rc"; return 1; fi
  _err=$(sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$_log" | head -n1)
  if [ -n "$_err" ]; then PULL_MSG="镜像源返回错误：$_err"; return 1; fi
  PULL_DIGEST=$(sed -n 's/.*"status":"Digest: \(sha256:[0-9a-f]\{64\}\)".*/\1/p' "$_log" | tail -n1)
  PULL_MSG="已完成（共收 ${_seen} 字节）"
  return 0
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
      printf ',"MacAddress":%s' "$_mac"
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
    if [ -n "$_mac" ] && [ -z "$_ip" ] && [ "$_driver" = "bridge" ]; then
      log "SKIP 网络 $_net 有 MAC 但无 IPv4，无法可靠区分自动/显式 MAC"
      return 1
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
S_ATTEMPTED=$P_ATTEMPTED
S_STARTED=${P_STARTED:-0}
EOF
}

load_plain_state() {
  . "$P_STATE"
  P_NAME="$S_NAME"; P_OLDNAME="$S_OLDNAME"; P_OLDCID="$S_OLDCID"
  P_NEWCID="$S_NEWCID"; P_OLDID="$S_OLDIMG"; P_NEWID="$S_NEWIMG"
  P_IMG="$S_IMG"; P_REPO="$S_REPO"; P_STAGE="$S_STAGE"; P_ATTEMPTED="$S_ATTEMPTED"
  P_STARTED="${S_STARTED:-0}"
}

plain_remove_state() {
  rm -f "$P_STATE"
  ACTIVE_KIND=""
  # 成功收尾清掉整个事务目录；回滚成功也清（容器已复原，无需保留现场）。
  # 只有回滚本身失败（EXIT_CODE=2）才保留目录供人工排查。
  if [ "${P_KEEP_EVIDENCE:-0}" = "1" ] && [ "${EXIT_CODE:-0}" = "2" ]; then
    :
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
  P_NEWCID=""; P_ATTEMPTED=0; P_STARTED=0
  if [ -f "$P_STATE" ]; then
    load_plain_state
    log "发现上次未完成事务，先执行恢复"
    plain_recover_current || return
    P_NEWCID=""; P_ATTEMPTED=0
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

  P_REMOTE=$(remote_digest "$P_IMG")
  [ -n "$P_REMOTE" ] || { log "ERR 无法获取远端 digest，本轮跳过"; plain_discard; return; }
  is_pinned_bad "$P_REPO" "$P_REMOTE" && { log "SKIP 远端版本仍在 :bad 钉住期"; plain_discard; return; }
  is_current "$P_OLDID" "$P_REMOTE" && { log "OK $P_NAME 已是最新 $P_REMOTE"; plain_discard; return; }
  [ "$DRY_RUN" != "1" ] || { log "DRY 发现新版本 $P_REMOTE，不执行"; plain_discard; return; }
  [ "$(left)" -gt $((T_UP + T_HEALTH + T_ROLLBACK + 15)) ] || { log "ERR 剩余时间预算不足，未改动"; plain_discard; return; }

  # 从暂存标签开始就建立事务；中断时也能还原被 pull 移动的 tag。
  P_OLDNAME="${P_NAME}__old_$(now)"
  P_NEWID=""
  ACTIVE_KIND="plain"; P_ATTEMPTED=0; P_STARTED=0
  save_plain_state
  docker tag "$P_OLDID" "$P_STAGE" 2>/dev/null || { plain_fail "无法暂存旧镜像" || return; return; }
  if ! pull_stream "$P_REPO" "$P_TAG" "$P_DIR/pull.log"; then
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

  P_ATTEMPTED=0; P_STARTED=0
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

  P_ATTEMPTED=1; save_plain_state
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
    _i=0; _hr=""
    while [ "$_i" -lt "$HEALTH_TRIES" ]; do
      _hr=$(docker inspect -f '{{.State.Health.Status}}' "$P_NEWCID" 2>/dev/null)
      [ "$_hr" = "healthy" ] && break
      case "$_hr" in unhealthy|exited|dead) break ;; esac
      _i=$((_i + 1)); [ "$(left)" -le "$T_ROLLBACK" ] && { _hr="预算不足"; break; }
      sleep 10
    done
    [ "$_hr" = "healthy" ] || { plain_fail "健康门禁未通过（$_hr）" || return; return; }
  else
    _i=0; _lim=$((PLAIN_BOOT / 2)); [ "$_lim" -ge 1 ] || _lim=1; _rn=true
    while [ "$_i" -lt "$_lim" ]; do
      _rn=$(docker inspect -f '{{.State.Running}}' "$P_NEWCID" 2>/dev/null)
      [ "$_rn" = "true" ] || break
      _i=$((_i + 1)); [ "$_i" -lt "$_lim" ] && sleep 2
    done
    _r1=$(docker inspect -f '{{.RestartCount}}' "$P_NEWCID" 2>/dev/null)
    [ "$_rn" = "true" ] || { plain_fail "新容器观察窗内退出" || return; return; }
    [ "${_r1:-0}" = "${_r0:-0}" ] || { plain_fail "新容器观察窗内发生重启" || return; return; }
  fi
  _reason=$(plain_spec_ok "$P_OLDCID" "$P_NEWCID" "$P_DIR")
  [ $? -eq 0 ] || { plain_fail "启动后规格复核失败：$_reason" || return; return; }

  # 成功：先保留当前旧容器为唯一回滚副本，再按 ID 清理上一份。
  docker tag "$P_OLDID" "$P_PREV" 2>/dev/null && log "回滚点已更新为 $P_PREV"
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

compose_args() {
  _args="-p $COMPOSE_NAME"
  if [ -n "$C_CFILES" ]; then
    for _f in $(printf '%s' "$C_CFILES" | tr ',' ' '); do _args="$_args -f $_f"; done
  fi
  [ -n "$C_ENVFILE" ] && _args="$_args --env-file $C_ENVFILE"
  printf '%s' "$_args"
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
  case "$C_DIR$C_CFILES$C_ENVFILE" in *[[:space:]]*) log "ERR Compose 路径含空白字符，当前安全解析不支持"; C_DIR=""; return 1 ;; esac
  return 0
}

proj_containers() {
  docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_NAME}" --format '{{.Names}}' 2>/dev/null
}

proj_images() {
  (cd "$C_DIR" && docker compose $(compose_args) config --images 2>/dev/null) | awk '!seen[$0]++'
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
  _up_at=$(now); _i=0
  while [ "$_i" -lt "$HEALTH_TRIES" ]; do
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
    _i=$((_i + 1)); [ "$(left)" -le "$T_ROLLBACK" ] && { echo "健康等待预算不足"; return 1; }
    sleep 10
  done
  echo "健康门禁超时"; return 1
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
  (cd "$C_DIR" && timeout -s KILL "$T_ROLLBACK" docker compose $(compose_args) up -d --force-recreate) || {
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
    REMOTE=$(remote_digest "$IMG")
    [ -n "$REMOTE" ] || { log "ERR 无法获取 $IMG 远端 digest，本轮跳过整个项目"; compose_discard; return; }
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
  [ "$(left)" -gt $((T_UP + T_HEALTH + T_ROLLBACK + 15)) ] || { log "ERR 剩余预算不足，未改动"; compose_discard; return; }

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
  compose_stage_tags || { log "ERR 旧镜像暂存失败，未改动"; compose_abort_before_up; return; }
  _fail=0
  while IFS='|' read -r _img _old _repo _tag; do
    if ! pull_stream "$_repo" "$_tag" "$C_WORK/pull-$(safe_key "$_repo").log"; then
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
  if [ "$_fail" = "1" ]; then compose_abort_before_up; log "ERR 拉取未完成，容器未切换"; return; fi

  C_PHASE="postup"
  cat > "$C_STATE" <<EOF
COMPOSE_NAME=$COMPOSE_NAME
C_DIR=$C_DIR
C_CFILES=$C_CFILES
C_ENVFILE=$C_ENVFILE
C_MAP=$C_MAP
C_PHASE=$C_PHASE
EOF
  (cd "$C_DIR" && timeout -s KILL "$T_UP" docker compose $(compose_args) up -d --force-recreate) || {
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
    docker tag "$_old" "$_repo:prev" 2>/dev/null && log "回滚点已更新为 $_repo:prev"
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
  acquire_lock
  resolve_compose || exit 1
  [ -n "$C_DIR" ] || {
    log "ERR 找不到 Compose 项目 $COMPOSE_NAME"
    log "    该项目没有运行中的容器可供发现目录，请用 --compose-dir 指定项目目录"
    exit 1
  }
  compose_update
elif [ -z "$COMPOSE_NAME" ] && [ -n "$CONTAINER_NAME" ]; then
  check_deps
  acquire_lock
  api_negotiate || exit 1
  plain_update
else
  log "ERR 必须且只能指定一个更新目标"
  log "    当前 COMPOSE_NAME='$COMPOSE_NAME' CONTAINER_NAME='$CONTAINER_NAME'"
  log "    用 --compose <名> 或 --container <名> 指定，或用 --help 查看用法"
  exit 1
fi

if [ "$EXIT_CODE" -ne 2 ]; then
  if [ -n "${P_REPO:-}" ]; then expire_bad "$P_REPO"; clean_orphans "$P_REPO"; fi
  if [ -n "${REPO:-}" ]; then expire_bad "$REPO"; clean_orphans "$REPO"; fi
fi
log "本轮结束，总耗时 $(elapsed)s"
exit "$EXIT_CODE"
