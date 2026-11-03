# 发版流程（维护者）

## 发版流程

1. 改脚本 → 升 `VERSION`（`container-autoupdate.sh` 里唯一那一行）。
2. 本地核对：`sh -n container-autoupdate.sh`、`python3 scripts/check-docs.py .`、`sh container-autoupdate.sh --version`。
3. 提交并推到 `main` → GitHub Actions 自动打 tag `v$VERSION` 并发布 Release。
4. 工作流是幂等的：**tag 与 Release 都存在**才跳过。只判 tag 是不行的——Release 那步失败过而 tag 已推上去时，会永远 skip，版本再也发不出去（v4.0.2 实测踩到）。tag 已存在时工作流跳过打 tag，直接补发 Release（带 4 次重试）。

改脚本却不升 `VERSION`，`releases/latest/download/` 会继续发旧代码。

## 资产

Release 里两个资产，由工作流上传：

| 资产 | 用途 |
|---|---|
| `container-autoupdate.sh` | 主脚本（唯一需要的东西） |
| `ct-stale-lock-check.sh` | 只读排查工具 |

工作流里有一道 `test ! -e ct-bootstrap.sh` 守卫：v3.0.0 起不再有引导器，仓库里一旦又冒出这个文件就会失败。

## 发版后核对

三方 sha256 必须一致：本地文件、`git show HEAD:container-autoupdate.sh`、线上 `releases/latest/download/container-autoupdate.sh`。再跑一次 `sh <下载的文件> --version` 确认版本号。
