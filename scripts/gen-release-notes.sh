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
#   2. 本版新增的破坏性变更（从脚本内 BREAKING_TABLE 按版本区间筛出）
#   3. 上一个 tag 到本次的提交列表
# 末尾附脚本文件的 sha256 / 大小 / 行数与下载命令。
#
# 兼容性要求：只用 POSIX sh 与 POSIX awk（Ubuntu 默认 awk 是 mawk，
# 不认 \s、\x27 这类 GNU 扩展，所以这里一律用 [[:space:]] 和 sprintf("%c",39)）。

set -eu

SCRIPT_FILE="${SCRIPT_FILE:-container-autoupdate.sh}"
VERSION="${VERSION:?需要设置 VERSION 环境变量}"
PREV_TAG="${PREV_TAG:-}"
TAG="v$VERSION"

if [ ! -f "$SCRIPT_FILE" ]; then
  echo "ERR 找不到脚本文件：$SCRIPT_FILE" >&2
  exit 1
fi

PREV_VER="${PREV_TAG#v}"

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
# 2) 破坏性变更：解析脚本里的 BREAKING_TABLE，只保留
#    「版本 <= 本版」且「版本 > 上一版」的登记项。
#    每行格式：版本|类别|旧写法|新写法|说明
# ---------------------------------------------------------------------------
BREAK_ROWS=$(awk -v cur="$VERSION" -v prev="$PREV_VER" '
  function trim(s) {
    gsub(/^[[:space:]]+/, "", s)
    gsub(/[[:space:]]+$/, "", s)
    return s
  }
  # 版本号转可比较的整数：1.2.3 -> 1*10^6 + 2*10^3 + 3
  function vkey(s,   n, a, i, k) {
    n = split(s, a, ".")
    k = 0
    for (i = 1; i <= 3; i++) k = k * 1000 + (a[i] + 0)
    return k
  }
  BEGIN {
    q = sprintf("%c", 39)          # 单引号；不能直接写，会破坏 shell 引号
    qhead = "^" q                  # 行首单引号
    qtail = q "[[:space:]]*$"      # 行尾单引号
    in_tbl = 0
    nl = 0
  }
  # BREAKING_TABLE 开始：可能同行就有内容，也可能是多行形式
  /^BREAKING_TABLE=/ {
    rest = substr($0, index($0, "=") + 1)
    rest = trim(rest)
    if (rest == q) {
      in_tbl = 1                   # 多行形式：TABLE=\x27 换行 … 换行 \x27
    } else if (rest != "") {
      sub(qhead, "", rest)         # 单行形式：TABLE=\x27a|b|c\x27
      sub(qtail, "", rest)
      if (rest != "") { nl++; lines[nl] = rest }
    }
    next
  }
  in_tbl {
    if ($0 == q) { in_tbl = 0; next }
    nl++; lines[nl] = $0
  }
  END {
    for (i = 1; i <= nl; i++) {
      line = lines[i]
      if (line ~ /^[[:space:]]*#/) continue      # 注释
      if (line ~ /^[[:space:]]*$/) continue      # 空行
      n = split(line, f, "|")
      if (n < 4) continue
      v = trim(f[1])
      if (v == "") continue
      kv = vkey(v)
      if (kv > vkey(cur)) continue                       # 比本版新：还没发生
      if (prev != "" && kv <= vkey(prev)) continue       # 上一版之前：早就发过
      cat  = trim(f[2])
      old  = trim(f[3])
      new  = trim(f[4])
      desc = trim(f[5])
      if (cat == "flag")      kind = "命令行参数"
      else if (cat == "env")  kind = "环境变量"
      else                    kind = "默认行为"
      printf "- **%s**（%s）：`%s` → `%s`\n", v, kind, old, new
      if (desc != "") printf "  %s\n", desc
    }
  }
' "$SCRIPT_FILE" 2>/dev/null || true)

# ---------------------------------------------------------------------------
# 3) 提交列表
# ---------------------------------------------------------------------------
if [ -n "$PREV_TAG" ]; then
  RANGE="$PREV_TAG..HEAD"
else
  RANGE="HEAD"
fi
COMMITS=$(git log --no-merges --pretty='- %s（%h）' "$RANGE" 2>/dev/null | head -n 40 || true)

# ---------------------------------------------------------------------------
# 4) 文件信息
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
# 维护者提醒：主/次版本号变了但没有登记破坏性变更时，发一条 workflow 警告。
# 没登记的破坏性变更对使用者是完全静默的，这是最容易犯的错。
# ---------------------------------------------------------------------------
if [ -n "$PREV_VER" ]; then
  CUR_MM=$(printf '%s' "$VERSION" | cut -d. -f1,2)
  PREV_MM=$(printf '%s' "$PREV_VER" | cut -d. -f1,2)
  if [ "$CUR_MM" != "$PREV_MM" ] && [ -z "$BREAK_ROWS" ]; then
    echo "::warning::VERSION 从 $PREV_VER 升到 $VERSION（主/次版本号有变化），但 BREAKING_TABLE 里没有对应登记。若这次含破坏性变更请补登记；若只是新增能力，可忽略此提示。"
  fi
fi

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
echo "## 本版内容"
echo ""
if [ -n "$DESC" ]; then
  echo "$DESC"
  echo ""
fi

if [ -n "$BREAK_ROWS" ]; then
  echo "### 破坏性变更"
  echo ""
  echo "$BREAK_ROWS"
  echo ""
  echo "> 用 \`releases/latest/download/\` 的用户如果仍在用上面的旧写法，脚本会立刻"
  echo "> 停下并给出迁移方式（退出码 3），不会静默出错。"
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

echo "### 下载"
echo ""
echo '```sh'
echo "curl -fsSL -L https://github.com/geekMus/container-autoupdate/releases/download/$TAG/container-autoupdate.sh \\"
echo "  -o container-autoupdate.sh && chmod +x container-autoupdate.sh"
echo '```'
echo ""
echo "想跟随最新发布版（地址不含版本号，直接粘）："
echo ""
echo '```sh'
echo "curl -fsSL -L https://github.com/geekMus/container-autoupdate/releases/latest/download/container-autoupdate.sh \\"
echo "  -o container-autoupdate.sh && chmod +x container-autoupdate.sh"
echo '```'
echo ""
echo "> \`-L\` 不能省：\`releases/latest/download/\` 会返回 302 跳转。"
echo "> 国内网络可给上面任意地址加前缀 \`https://github.mus.pp.ua/\` 或 \`https://gh-proxy.com/\`。"
echo ""

echo "| 项目 | 值 |"
echo "|---|---|"
echo "| 版本 | \`$VERSION\` |"
echo "| SHA256 | \`$SHA\` |"
echo "| 大小 | $BYTES 字节 |"
echo "| 行数 | $LINES 行 |"
