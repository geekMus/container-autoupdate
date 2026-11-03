#!/bin/sh
# 生成 Release 发布说明（以及 tag 消息）。完全自动，不需要人工写。
#
# 由 .github/workflows/release.yml 调用，也可以本地手动跑：
#
#   VERSION=1.2.3 PREV_TAG=v1.2.2 sh scripts/gen-release-notes.sh
#
# 输入（环境变量）：
#   VERSION      必填，本次发布的版本号（不带 v 前缀）
#   PREV_TAG     可选，上一个发布 tag（如 v0.1.0）；留空表示这是首个发布
#   SCRIPT_FILE  可选，脚本路径，默认 container-autoupdate.sh
#
# 输出：发布说明写到 stdout。
#
# 说明内容由三部分组成，全部来自仓库自身：
#   1. 脚本头部注释里的定位句
#   2. 上一个 tag 到本次的提交列表
#   3. 安装 / 更新的那一段（与 README 的「快速开始」逐行一致）
# 末尾附脚本文件的 sha256 / 大小 / 行数。
#
# 兼容性要求：只用 POSIX sh 与 POSIX awk（Ubuntu 默认 awk 是 mawk，
# 不认 \s、\x27 这类 GNU 扩展，所以这里一律用 [[:space:]]）。

set -eu

SCRIPT_FILE="${SCRIPT_FILE:-container-autoupdate.sh}"
VERSION="${VERSION:?需要设置 VERSION 环境变量}"
PREV_TAG="${PREV_TAG:-}"
TAG="v$VERSION"

if [ ! -f "$SCRIPT_FILE" ]; then
  echo "ERR 找不到脚本文件：$SCRIPT_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1) 定位句：脚本头部注释里的第一段正文
#    头部通常是 `#!/bin/sh` + `# ==== 横幅 ====` + 一段说明。规则：跳过 shebang
#    与开头的横幅分隔线，从第一条真正的注释正文开始，累积到「空注释行(#)」或
#    「非注释行」为止，拼成一行。
# ---------------------------------------------------------------------------
DESC=$(awk '
  /^#!.*/ { next }
  !started {
    if ($0 ~ /^#[[:space:]]*=+/) next      # 横幅分隔线
    if ($0 ~ /^#/) { started = 1 } else { exit }
  }
  started {
    if ($0 !~ /^#/) exit                   # 注释段结束
    line = $0
    sub(/^#[[:space:]]*/, "", line)
    if (line == "") exit                   # 空注释行 = 段落结束
    # 中文句子在换行处不该插入空格：若上一段以中文/全角标点结尾，直接拼接。
    if (out == "") { out = line }
    else if (out ~ /[一-龥，、。：；！？（）「」《》—…]$/) { out = out line }
    else { out = out " " line }
  }
  END { printf "%s", out }
' "$SCRIPT_FILE" 2>/dev/null || true)

# ---------------------------------------------------------------------------
# 2) 提交列表
# ---------------------------------------------------------------------------
if [ -n "$PREV_TAG" ]; then
  RANGE="$PREV_TAG..HEAD"
else
  RANGE="HEAD"
fi
COMMITS=$(git log --no-merges --pretty='- %s（%h）' "$RANGE" 2>/dev/null | head -n 40 || true)

# ---------------------------------------------------------------------------
# 3) 文件信息
# ---------------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  SHA=$(sha256sum "$SCRIPT_FILE" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  SHA=$(shasum -a 256 "$SCRIPT_FILE" | cut -d' ' -f1)
else
  SHA="（无法计算，缺少 sha256sum）"
fi
BYTES=$(wc -c < "$SCRIPT_FILE" | tr -d ' ')
LINES=$(wc -l < "$SCRIPT_FILE" | tr -d ' ')

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
echo "## 本版内容"
echo ""
if [ -n "$DESC" ]; then
  echo "$DESC"
  echo ""
fi

echo "### 变更"
echo ""
if [ -n "$COMMITS" ]; then
  echo "$COMMITS"
else
  echo "（没有新的提交）"
fi
echo ""

echo "### 安装 / 更新"
echo ""
echo "把下面整段填进 DPanel 计划任务的「脚本」框（一个脚本就够）。"
echo ""
echo '```sh'
echo "SRC='https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh"
echo "https://ghfast.top/https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh"
echo "https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh'"
echo "T=/tmp/ct-new.sh"
echo 'okfile() { [ "$(wc -c <"$1" 2>/dev/null || echo 0)" -gt 1000 ] && sh -n "$1" 2>/dev/null && grep -q container-autoupdate "$1"; }'
echo 'for u in $SRC; do'
echo '  curl -fsSL --max-time 30 "$u" -o "$T" 2>/dev/null || continue'
echo '  okfile "$T" && break'
echo 'done'
echo 'okfile "$T" && mv -f "$T" /tmp/container-autoupdate.sh'
echo '[ -s /tmp/container-autoupdate.sh ] || { echo "ERR 拿不到可用的更新脚本"; exit 1; }'
echo 'sh /tmp/container-autoupdate.sh --compose myapp'
echo '```'
echo ""
echo "想锁死本版：把 \`SRC\` 里每一行的 \`latest/download\` 换成 \`download/$TAG\`。"
echo ""

echo "排查残留进程和旧锁文件（只读脚本，不改任何东西）："
echo ""
echo '```sh'
echo "curl -fsSL -L https://gh-proxy.com/https://github.com/geekMus/container-autoupdate/releases/latest/download/ct-stale-lock-check.sh \\"
echo "  -o /tmp/ct-stale-lock-check.sh"
echo "sh /tmp/ct-stale-lock-check.sh"
echo '```'
echo ""

echo "| 项目 | 值 |"
echo "|---|---|"
echo "| 版本 | \`$VERSION\` |"
echo "| SHA256 | \`$SHA\` |"
echo "| 大小 | $BYTES 字节 |"
echo "| 行数 | $LINES 行 |"
