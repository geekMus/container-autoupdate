#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文档检查：本地链接与锚点、Markdown 表格结构、CRLF、残留的英文副本。

文档只维护中文版（README + docs 四份），所以这里不再做中英对照检查。

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

DOCS = [
    "README.md",
    "docs/how-it-works.md",
    "docs/parameters.md",
    "docs/advanced-usage.md",
    "docs/releasing.md",
]

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")

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
    t = title.strip().replace("`", "").replace("**", "").lower()
    t = re.sub(r"[^\w\s\-\u4e00-\u9fff]", "", t)
    return t.replace(" ", "-")


def headings(path):
    """返回该文件的标题锚点集合（代码块内的 '#' 不算标题）。"""
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
    for path in DOCS:
        full = os.path.join(root, path)
        if not os.path.exists(full):
            continue
        with open(full, "rb") as fh:
            if b"\r" in fh.read():
                err("%s 含 CRLF 行尾，请转换为 LF" % path)


def check_links(root, path):
    """本地链接：目标文件存在 + 锚点能对上目标文件的标题。"""
    text = strip_code(read(os.path.join(root, path)))
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
    """数一行的表格列数（转义的竖线 `\\|` 不算列分隔符）。"""
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


def check_no_en_copies(root):
    """英文副本已取消：文档只维护中文版，仓库里不该再出现 *.en.md。"""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for name in filenames:
            if name.endswith(".en.md"):
                rel = os.path.relpath(os.path.join(dirpath, name), root)
                err("文档只维护中文版，但仓库里还有英文副本：%s" % rel.replace(os.sep, "/"))


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")

    for path in DOCS:
        if not os.path.exists(os.path.join(root, path)):
            err("缺少文档 %s" % path)

    check_line_endings(root)
    for path in DOCS:
        if os.path.exists(os.path.join(root, path)):
            check_links(root, path)
            check_tables(root, path)
    check_no_en_copies(root)

    if errors:
        print("")
        print("文档检查未通过，共 %d 个问题。" % len(errors))
        return 1
    print("文档检查通过：本地链接与锚点、表格结构、CRLF 均正常。")
    return 0


if __name__ == "__main__":
    sys.exit(main())