#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文档一致性检查：语言切换条、本地链接与锚点、Markdown 表格结构、CJK 残留。

在 CI 里跑（.github/workflows/ci.yml 的「文档检查」步骤）。
纯标准库实现，ubuntu runner 自带 python3。

退出码：0 = 全部通过；1 = 有问题（每条问题打印一行 `::error::`）。

用法：
    python3 scripts/check-docs.py            # 检查仓库根目录下的文档
    python3 scripts/check-docs.py <目录>      # 检查指定目录
"""

import os
import re
import sys

# 中文（默认）文档 与 英文副本 的对应关系
PAIRS = [
    ("README.md", "README.en.md"),
    ("docs/how-it-works.md", "docs/how-it-works.en.md"),
    ("docs/parameters.md", "docs/parameters.en.md"),
    ("docs/advanced-usage.md", "docs/advanced-usage.en.md"),
    ("docs/releasing.md", "docs/releasing.en.md"),
]

ZH_FILES = [zh for zh, _ in PAIRS]
EN_FILES = [en for _, en in PAIRS]

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")
CJK_RE = re.compile(r"[\u4e00-\u9fff]")

errors = []


def err(msg):
    errors.append(msg)
    print("::error::%s" % msg)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def strip_code(text):
    """去掉围栏代码块，避免把示例里的链接算进来。"""
    return re.sub(r"```.*?```", "", text, flags=re.S)


def slug(title):
    """GitHub 锚点规则：转小写、空格转连字符、去掉标点（含反引号/括号/点）。"""
    t = title.strip()
    t = t.replace("`", "")
    t = t.replace("**", "")
    t = t.lower()
    t = re.sub(r"[^\w\s\-\u4e00-\u9fff]", "", t)
    return t.replace(" ", "-")


def headings(path):
    """返回该文件的标题集合（代码块内的 '#' 不算标题）。"""
    out = set()
    incode = False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.lstrip().startswith("```"):
                incode = not incode
                continue
            if incode:
                continue
            m = HEADING_RE.match(line)
            if m:
                out.add(slug(m.group(2)))
    return out


def check_line_endings(root):
    for zh, en in PAIRS:
        for path in (zh, en):
            full = os.path.join(root, path)
            if not os.path.exists(full):
                continue
            with open(full, "rb") as fh:
                data = fh.read()
            if b"\r" in data:
                err("%s 含 CRLF 行尾，请转换为 LF" % path)


def check_switch_bar(root):
    for zh, en in PAIRS:
        zpath = os.path.join(root, zh)
        epath = os.path.join(root, en)
        if os.path.exists(zpath):
            head = "\n".join(read(zpath).split("\n")[:5])
            if not re.search(r"^> 语言：\[中文\]", head, re.M):
                err("%s 缺少语言切换条（H1 正下方应有「> 语言：[中文](...) | [English](...)」）" % zh)
        if os.path.exists(epath):
            head = "\n".join(read(epath).split("\n")[:5])
            if not re.search(r"^> Language: \[English\]", head, re.M):
                err("%s 缺少语言切换条（H1 正下方应有「> Language: [English](...) | [中文](...)」）" % en)


def check_links(root, path, expect_en):
    """检查单个文件里的本地链接：目标文件存在 + 锚点能对上目标文件的标题。"""
    full = os.path.join(root, path)
    text = strip_code(read(full))
    base = os.path.dirname(path)
    for m in LINK_RE.finditer(text):
        target = m.group(2)
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        filepart, _, anchor = target.partition("#")
        target_path = os.path.normpath(os.path.join(base, filepart)) if filepart else path
        if filepart and not os.path.exists(os.path.join(root, target_path)):
            err("%s 里的链接指向不存在的文件：%s" % (path, target))
            continue
        if anchor and anchor not in headings(os.path.join(root, target_path)):
            err("%s 里的链接锚点对不上：%s（%s 里没有对应标题）" % (path, target, target_path))


def count_columns(row):
    """数一行的表格列数。

    转义的竖线 `\\|`（常见于代码块里的 `tr '\\0' ' '`）不算列分隔符，
    否则会把一列误判成两列。
    """
    body = row.strip()
    body = body[1:] if body.startswith("|") else body
    body = body[:-1] if body.endswith("|") and not body.endswith("\\|") else body
    return len(re.split(r"(?<!\\)\|", body))


def check_tables(root, path):
    full = os.path.join(root, path)
    incode = False
    ncol = 0
    with open(full, encoding="utf-8") as fh:
        for no, line in enumerate(fh, 1):
            if line.lstrip().startswith("```"):
                incode = not incode
                ncol = 0
                continue
            if incode:
                continue
            s = line.strip()
            if not s.startswith("|"):
                ncol = 0
                continue
            # 塌行检测：`| a | ... || b | ...` 会让表格塌掉（AGENTS.md §8）
            if re.search(r"\|\|\s*\S", s) and not re.match(r"^\|[\s\-:|]+\|$", s):
                err("%s:%d 表格疑似塌成一行：%s" % (path, no, s[:80]))
            cols = count_columns(s)
            if ncol == 0:
                ncol = cols
            elif cols != ncol:
                err("%s:%d 表格列数 %d 与表头 %d 不一致：%s" % (path, no, cols, ncol, s[:80]))


def heading_list(path):
    """返回该文件的标题列表（代码块内的 '#' 不算标题）。"""
    out = []
    incode = False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.lstrip().startswith("```"):
                incode = not incode
                continue
            if incode:
                continue
            m = HEADING_RE.match(line)
            if m:
                out.append((len(m.group(1)), m.group(2)))
    return out


def check_heading_parity(root):
    """中英标题的层级与数量必须一致（英文只是翻译，不多不少不少章节）。"""
    for zh, en in PAIRS:
        zpath = os.path.join(root, zh)
        epath = os.path.join(root, en)
        if not (os.path.exists(zpath) and os.path.exists(epath)):
            continue
        a = heading_list(zpath)
        b = heading_list(epath)
        if len(a) != len(b):
            err("%s 与 %s 的标题数量不一致：中文 %d 个，英文 %d 个"
                % (zh, en, len(a), len(b)))
            continue
        for i, (x, y) in enumerate(zip(a, b)):
            if x[0] != y[0]:
                err("%s 与 %s 第 %d 个标题的层级不一致：中文 h%d「%s」，英文 h%d「%s」"
                    % (zh, en, i + 1, x[0], x[1], y[0], y[1]))


def check_cjk(root):
    """英文文档里不应残留中文，除了：脚本日志原文、代码标识符、切换条里的「中文」二字。

    「代码标识符」与「脚本日志原文」在英文文档里都用反引号包着，
    所以先把行内代码片段摘掉再判断；围栏代码块整块放过（里面是脚本真实输出）。
    """
    for path in EN_FILES:
        full = os.path.join(root, path)
        if not os.path.exists(full):
            continue
        incode = False
        with open(full, encoding="utf-8") as fh:
            for no, line in enumerate(fh, 1):
                if line.lstrip().startswith("```"):
                    incode = not incode
                    continue
                if incode:
                    # 代码块里只允许脚本日志原文与代码标识符，逐行放过
                    continue
                # 摘掉行内代码（`...`）与链接文字
                stripped = re.sub(r"`[^`]*`", "", line)
                stripped = re.sub(r"\[[^\]]*\]\([^)]*\)", "", stripped)
                if CJK_RE.search(stripped):
                    # 切换条里的「中文」二字
                    if re.match(r"^> Language: \[English\].*中文", line.strip()):
                        continue
                    err("%s:%d 英文文档里残留中文（脚本日志原文与代码标识符除外）：%s"
                        % (path, no, line.strip()[:80]))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    root = os.path.abspath(root)

    for zh, en in PAIRS:
        if not os.path.exists(os.path.join(root, zh)):
            err("缺少中文文档 %s" % zh)
        if not os.path.exists(os.path.join(root, en)):
            err("缺少英文副本 %s" % en)

    check_line_endings(root)
    check_switch_bar(root)

    for zh, en in PAIRS:
        for path in (zh, en):
            if os.path.exists(os.path.join(root, path)):
                check_links(root, path, path.endswith(".en.md"))
                check_tables(root, path)

    check_cjk(root)
    check_heading_parity(root)

    if errors:
        print("")
        print("文档检查未通过，共 %d 个问题。" % len(errors))
        return 1
    print("文档检查通过：语言切换条、本地链接与锚点、表格结构、CRLF 均正常。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
