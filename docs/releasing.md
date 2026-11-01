# 发版流程（维护者用）

> 给使用者的说明看 [README](../README.md)。这里只讲**怎么发一个新版本**。

## 一句话

改脚本里的 `VERSION` → 提交到 `main` → 剩下的全自动。

## 具体步骤

1. 修改 `container-autoupdate.sh`，把版本号改掉：

   ```sh
   VERSION="1.2.3"    # 改成新版本，例如 "1.2.4"
   ```

2. 提交并推到 `main`：

   ```sh
   git add container-autoupdate.sh
   git commit -m "feat: ..."
   git push origin main
   ```

3. GitHub Actions 自动执行（`.github/workflows/release.yml`）：

   | 步骤 | 做什么 |
   |---|---|
   | 检出代码 | `fetch-depth: 0`，要把历史 tag 也拉下来 |
   | 校验脚本 | `sh -n` 语法检查、CRLF 行尾检查、git 里必须 `100755` 可执行 |
   | 读取 VERSION | 从脚本里读出 `VERSION="x.y.z"`，校验只含数字和点 |
   | 判断是否需要发版 | tag `vx.y.z` 已存在就整个跳过（幂等） |
   | 找上一个发布 tag | 取「比当前版本小的最大者」，用 awk 比三段数字（不依赖 `sort -V`） |
   | 生成发布说明 | `scripts/gen-release-notes.sh` → 定位句 + 本版破坏性变更 + 提交列表 + 下载命令 + sha256 |
   | 打 tag | tag `vx.y.z` 不存在就创建（annotated，**消息就是发布说明**） |
   | 发布 Release | 不存在就创建，用发布说明作正文，**同时上传两个资产**：`container-autoupdate.sh` 与 `ct-bootstrap.sh` |

   完成后，`releases/latest/download/container-autoupdate.sh` 和 `releases/latest/download/ct-bootstrap.sh` 都指向新版本。

   > 两个资产都要传。少传一个，对应的 `releases/latest/download/...` 就是 404。

   > 发布说明是自动生成的，不用人工写；`git show vx.y.z` 也能看到改了什么（tag 消息即发布说明）。

## 版本号规则

语义化版本，三段数字：

| 场景 | 示例 |
|---|---|
| 修 bug、改文案、补日志（不影响调用方式） | `1.2.3` → `1.2.4` |
| 加参数、加能力，行为向后兼容 | `1.2.4` → `1.3.0` |
| 改了默认行为、用户需要改配置 | `1.3.0` → `2.0.0` |

**如果这次变更会让用户已有的调用方式失效**（参数改名、环境变量改名、默认行为改变），必须做两件事：

1. 把变更登记进脚本的 `BREAKING_TABLE`（格式见脚本内注释）；
2. 按上表升级到破坏性对应的版本段。

登记之后，用户用 `latest` 时脚本会自己停下并给出迁移说明（退出码 `3`），或用 `--compat` 声明过验证范围时会硬停。没登记的破坏性变更对使用者是完全静默的——这是最容易犯的错。

`VERSION` 只能包含数字和点，否则工作流会报错并中止（不会发出半成品版本）。

## 幂等性

工作流是幂等的，重复跑不会出问题：

- tag 已存在 → 跳过打 tag；
- Release 已存在 → 跳过发布。

所以「改了文档也顺手推一下 main」不会产生多余版本；只有 `VERSION` 真的变了才会有新 tag。

## 分支限制

发版**只在 `main` 上执行**：

- `release.yml` 的触发条件是 `push` 到 `main`；
- job 里还有一道 `if: github.ref == 'refs/heads/main'`，手动触发（`workflow_dispatch`）选到别的分支时直接跳过。

其他分支和 PR 走 `.github/workflows/ci.yml`，只做校验（语法、行尾、`--help` 可用），不发版。

## 出问题怎么查

1. 仓库 **Actions** 页看最近一次 `Release` 运行的日志，哪个步骤红了会有 `::error::` 说明原因。
2. 常见原因：
   - **VERSION 格式不合法** —— 带字母、带 `v` 前缀都不行，要写 `1.2.3` 而不是 `v1.2.3`。
   - **脚本有 CRLF 行尾** —— 校验步骤会拦下。本地用 `.gitattributes`（已配置 `*.sh text eol=lf`）可以避免。
   - **`sh -n` 语法错误** —— 提交前本地先跑一次。
3. 想重发某版本：先把 `VERSION` 改回旧值（或改成一个新值），再推一次 `main`。若 tag 和 Release 都已存在，工作流会全部跳过，什么都不改。
4. 确实需要删掉某个 Release：在 GitHub 页面删 Release 和 tag，再把 `VERSION` 改成别的值推一次，或手动触发工作流。

## 为什么用 Release 资产而不是 raw 链接

`raw.githubusercontent.com/<owner>/<repo>/<ref>/<file>` 在部分网络环境经常连不上（实测多次 8 秒超时），而且 `/main/` 这种 ref 会让使用者跟着**未发布**的中间状态跑。

Release 资产 + `releases/latest/download/` 的好处：

- 地址里**不含版本号**，使用者粘贴一次就不用再改；
- 只指向**正式发布**的版本，不会拿到半成品；
- 加速服务（`gh-proxy.com`、`ghproxy.net`、自建那套）都能代理 Release 资产，实测 15MB 文件 5.9 秒下载完成。
