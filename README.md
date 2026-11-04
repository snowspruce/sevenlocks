# sevenlocks

单台开发机上约束多个 AI 会话并行改同一个仓库的模板包。脚本、git 钩子与 CI 门禁组成七层防护，每条规则都来自真实事故复盘。

本仓只放可直接复制的东西。每层设计依据与 25 条实战坑见 [`SEVEN_LOCKS.md`](SEVEN_LOCKS.md)，版本历史见 [`CHANGELOG.md`](CHANGELOG.md)。

---

## 这是什么，不是什么

- **是**：一套在**单台开发机**上约束「多个 AI 会话并行改同一个仓库」的工作流 + 脚本——
  会话 worktree 隔离、pathspec 提交、推送守卫、部署排队锁与隔离树、编辑时拦截、跨会话
  冲突雷达。每条规则都来自真实事故复盘（见 `SEVEN_LOCKS.md` 的坑清单）。
- **不是**：分布式调度平台、CI/CD SaaS、多机编排系统。默认假设：开发机一到两台、部署从
  单机发起、仓库直推分支（无强 PR 流程）。超出这个形态请先读 `SEVEN_LOCKS.md`「适用边界」
  ——PR 流程 + 部署全在 CI 的项目应优先用平台现成能力，不要自建。
- 可移植的最小面 = `scripts/` 下的脚本 + `AGENTS-conventions.md` 的约定节；`README.md` /
  `SEVEN_LOCKS.md` 是参考文档，**不要逐字抄进项目**（会制造 N 份待同步副本）。

---

## 它解决什么问题

多个 AI 编码会话同时在一个仓库上干活，事故通常不是「AI 不会写代码」，而是**共享状态没有
隔离**：一个会话的工作区、暂存区、分支、部署动作，会被另一个会话无意识地覆盖或带走。
本体系把这类事故逐条变成机制（全部来自真实复盘，完整坑清单见 `SEVEN_LOCKS.md`）：

| 事故形态 | 典型现场 | 后果 / 暴露方式 |
|---|---|---|
| 同文件覆盖 | B 会话 `git restore` / `checkout` 把 A 会话正在改的文件抹掉 | 半天后改动消失，无法归因 |
| 暂存区裹挟 | 共享 checkout 里一次 `git add -A`，把别人 5 个未完成文件一起提交 | 别人的半成品被推上线 |
| 归属不明卡死 | 主 checkout 混着多个会话的脏文件，谁都不敢提交、也不敢部署 | 会话停下来问人 |
| 落后推送 | 基于陈旧基线 push，覆盖别人已推提交（rebase 后 SHA 全变，靠 patch-id 才判得出） | 提交「静默丢失」 |
| hub 直编 | 主 checkout 被当编辑区，长期落后 origin 还带着几十个脏文件 | 会话按旧代码做决策 |
| 部署互踩 | 两个会话同时部署同一台小内存服务器 | OOM，全站假死 |
| 回滚踩踏 | 用旧提交部署，把别人刚上的修复「倒退」掉 | 生产回到更旧版本 |
| 带红上线 | CI 没跑完 / 结论为红就部署 | 坏代码进生产 |
| 评估跨版本 | eval 跑在部署中途，结果混了两个代码版本 | 结论不可归因 |
| 卫生腐烂 | /tmp 残留 worktree、只在单机的备份、被中断的部署没人知道 | 磁盘占满 / 备份丢失 |

核心取舍：**该并行的层（编辑/提交/推送/CI）彻底并行；必须串行的点（部署/评估）显式设闸。**
每条规则都落到「脚本 + git 钩子 + CI 门禁 / 部署闸」，**不依赖会话记得**。

---

## 七层保障

| 层 | 防什么 | 本仓机制 | 强制点 |
|---|---|---|---|
| **L1 编辑层** | 多会话共用一个工作区/index；hub 被直编；冲突到 push 才发现 | `session-wt.sh`（worktree 生命周期 + adopt + conflicts 雷达）、`agent-guard.py` + `claude-settings.json`（Claude Code 编辑时拦截）、`hooks/pre-commit` + `pre-merge-commit` | 每个会话独立 `<WT_ROOT>/wt-<name>`；hub 提交直接失败；改 hub、hub 整树 git、`--no-verify` 等在工具调用前被拒 |
| **L2 提交层** | `git add -A` 裹挟别人的文件；暂存区归属不清 | 会话 worktree（天然只含自己的改动）+ 提交一律 pathspec | 提交只带本 worktree 的变更；hub 上提交被 L1 钩子拦下 |
| **L3 推送层** | 落后基线推送覆盖他人提交；强推改写共享历史；误删保护分支 | `session-wt.sh push`（fetch + rebase + 推整支）、`push-mine.sh`（单提交幂等重放）、`hooks/pre-push` | push 前判落后/非快进/删保护分支；分叉用 patch-id 判等，不靠 SHA |
| **L4 CI 层** | 无关提交烧 CI 分钟；红 CI 无人看；无人值守带病上线 | `ci.yml.template`（changes job 路径过滤 + concurrency + 门禁分级） | 目录命中才跑对应 job；部署侧查 run 结论，无人值守时红 CI 硬拦 |
| **L5 部署层** | 并发部署互踩；部署带上本地未提交改动；旧提交回滚踩踏；切换窗口服务中断；中断无痕迹 | `deploy-skeleton.sh`（全局排队锁 + 隔离 worktree 部署树 + 单调前进闸 + staging 原子切换 + 历史留痕）、`deploy_watchdog.sh`（START 无 END 报出） | 同机串行（撞锁排队）；只部署 `origin/<dev>` 已推提交；防倒退闸（旧提交部署被拦）；版本戳可归因到 commit |
| **L6 评估层** | 评估结论混入不同代码版本；单跑把抖动当回归 | 评估全局串行 + 部署版本前后快照标注 + 失败确认重跑（两胜制）+ 通过率/成本联合口径 | 结论必须可归因到 commit；flaky 与真回归分开记 |
| **L7 运维卫生层** | /tmp 残留 worktree；备份只在单机；被中断部署无人知；审计看不见非 git 残留 | `session-wt.sh audit / gc-dirs / replicate`、`deploy_watchdog.sh`、钩子安装自检 | 每次 `start` 自动体检 + 机会式回收；备份推远端 `refs/backup/*`；中断部署在下一次部署时打印 |

> L1/L3/L5 是**硬拦**（脚本 / git 钩子直接拒绝），L4 是**门禁**，L6/L7 是**口径与体检**。
> 落地顺序建议（价值密度从高到低）：L5 全局锁 → L1/L3 worktree + 推送 → L4 门禁 →
> L7 卫生 → L2 约定 → L6 评估（有评估套件才需要）。

---

## 文件放置规则

| 文件 | 去向 | 约束（为什么不能随便放） |
|---|---|---|
| `scripts/session-wt.sh`、`scripts/push-mine.sh`、`scripts/deploy-skeleton.sh`（改名 `deploy.sh`）、`scripts/deploy_watchdog.sh`、`scripts/install-git-hooks.sh` | `<项目根>/scripts/` | **硬编码**：push-mine/deploy 用 `$SCRIPT_DIR/..` 推仓库根（放深一层就推错）；deploy 的隔离重入硬编码 `scripts/` 路径；ci.yml 路径过滤正则 `^scripts/`；watchdog 由 deploy/session-wt 按 `$SCRIPT_DIR` 调用 |
| `scripts/agent-guard.py`、`scripts/claude-settings.json` | guard → `<项目根>/scripts/agent-guard.py`；settings → `<项目根>/.claude/settings.json`（**提交进 git**） | 钩子命令用 `git rev-parse --show-toplevel` 定位 `<repo>/scripts/agent-guard.py`（换目录即失效）；项目已有 settings.json 时**只合并 `hooks.PreToolUse` 段**（该文件还承载 permissions/env，整体覆盖会丢配置）；不提交进 git → 各会话 worktree 里没有该文件，守卫在 worktree 会话中完全不生效（只在 hub 里改没用） |
| `scripts/verify-install.sh`、`scripts/tests/test_agent_guard.sh`、`scripts/tests/test_conflicts.sh` | `<项目根>/scripts/`（测试放 `scripts/tests/`） | verify 用 `$0` 同目录找 session-wt/push-mine/deploy-skeleton，**必须与它们同级**；两套测试用 `$0/../..` 定位仓库根，改层级要同步改 `REPO_ROOT`；`test_conflicts` 自动读被测脚本的 `SL_DEV_BRANCH`/`SL_MIRROR_BRANCH`，项目改过参数也能跑 |
| `hooks/pre-commit`、`hooks/pre-merge-commit`、`hooks/pre-push` | `<项目根>/scripts/hooks/`（三件齐全） | 安装器按 `scripts/hooks/<name>` 复制进 hooks 目录，缺任一件拒绝安装（预检） |
| `ci.yml.template` | 填完占位符存为 `.github/workflows/ci.yml` | GitHub 只执行 `.github/workflows/*.yml`；**.template 原件不拷进项目**（留在模板仓当参考） |
| `AGENTS-conventions.md` | 内容**并进**项目根 `AGENTS.md` / `CLAUDE.md`（占位符替换、放文件靠前） | 会话只自动读 AGENTS.md/CLAUDE.md 这类约定命名文件——散文件没人读 = 规约没装 |
| `README.md`、`SEVEN_LOCKS.md` | **不拷**，留在模板仓（snowspruce/sevenlocks） | 纯参考文档，拷进每个项目 = 制造 N 份待同步副本 |

适配只动各脚本的**参数层注释块**（分支名/锁路径/仓 slug/**gh 账号**（跨账号仓库必填，见 deploy 参数层）/接线清单/服务目标），通用逻辑零改动。

随手就错的反例：push-mine 放 `bin/` → 仓库根推导错、fetch/push 跑在错误目录；ci.yml.template 原样留在 workflows/ → 不会被执行；AGENTS-conventions.md 只拷到根目录不并入 → 每个会话都看不到规约。

---

## 无法写进通用代码的项目侧设置

通用脚本只实现机制；下面这些**只能由项目自己落**，模板里没有、也不该有：

| 设置 | 落点 | 不做会怎样 |
|---|---|---|
| Claude 钩子接线 | `.claude/settings.json`（内容来自 `claude-settings.json`，**提交进 git**） | 守卫不加载：hub 直改、`--no-verify` 全部照旧放行；只放本地不提交时，worktree 会话看不到 |
| 已有 settings.json 的合并 | 只并 `hooks.PreToolUse` 数组，保留 permissions/env/model 等键 | 整体覆盖会清掉项目既有权限与环境配置 |
| git 钩子安装 | 每台开发机执行一次 `./scripts/install-git-hooks.sh` | hooks 目录不被 git 跟踪，未装的机器上 hub 提交/落后推送照旧能过 |
| Claude Code 之外的 agent | 无增强层：ZCode / Codex / 手工终端靠 git 钩子 | 别把 guard 当成跨 agent 的写保护 |
| python3 可用 | 钩子命令 `exec python3 …`；缺失时命令以非 2 退出码放行 | 守卫静默失效（fail-open）；验证清单「编辑时拦截」一项会暴露 |
| 老 worktree 同步 | 已存在的 `<SL_WT_ROOT>/wt-*` rebase 到含 settings 的提交 | 旧 worktree 里没有 `.claude/settings.json`，该会话不被拦（新 `start` 基于 origin，天然满足） |
| CI workflow | `ci.yml.template` 填占位符 → `.github/workflows/ci.yml` | 门禁/可执行位/shellcheck 全不跑；`.template` 原样留在 workflows/ 不会被执行 |
| 参数层 | 各脚本参数块：分支名/镜像分支/锁与公告路径/仓 slug/gh 账号/接线清单/服务目标/`SL_WT_ROOT` | 推错分支、锁互踩、CI 404 永拒、接线错 |
| 部署服务段 | `deploy_services()` 按项目实现（服务器/staging/切换原语/健康检查） | L5 只装到通用闸门，真正发布跑不起来 |
| 真实环境三项验证 | 红 CI 硬拦、CI 路径过滤、单调前进闸 `--drill` | 本地 verify 只证通用层机制，不证这些 |
| 自托管 runner | 各实例 `.env` 注入 PATH（nvm/homebrew/python），多实例同步改 | web/go job 用错 node/python 版本 |

**项目已有自己的 deploy.sh（溶解式变体，2026-10-14 首例）**：旧脚本整体迁为
`scripts/deploy-services.sh`（服务段），新 `deploy.sh` = 通用段包装层（`deploy_services()`
调它，外部用法接口不变）；原脚本的只读模式（--status/--logs）在闸门前直通分流；迁移前
`grep -rn "deploy.sh" tests/ scripts/` 找**程序性读取旧脚本源码文本**的测试随迁改指（详见
SEVEN_LOCKS.md 坑 15）。

---

## 包内清单

| 文件 | 层 | 用途 |
|---|---|---|
| `session-wt.sh` | L1 | 会话 worktree 生命周期（start/list/push/**adopt**/clean/prune/gc-dirs/replicate/audit/**conflicts** + hub 保鲜 + 审计 + 孤儿回收 + 镜像同步；adopt=把主 checkout 指定 paths 的改动复制进 worktree，主 checkout 不删） |
| `push-mine.sh` | L3 | 单提交幂等重放推送（祖先链 + patch-id 双检） |
| `deploy-skeleton.sh` | L5 | 部署通用段骨架：全局排队锁 + CI 门禁分级 + 隔离部署树 + 单调前进闸 + 中断部署体检；服务段为定制插槽（扩展点） |
| `deploy_watchdog.sh` | L5 | 中断部署监视：START 无 END（SIGKILL/挂起）→ 下一次部署或 start 时主动报出；可接 `SL_ALERT_CMD` |
| `agent-guard.py` + `claude-settings.json` | L1 | 编辑时拦截（Claude Code `PreToolUse` 增强层）：hub 编辑/提交、`--no-verify`、`SKIP_PREPUSH_CHECK`、外部 `DEPLOY_IN_WORKTREE`、hub 整树覆盖 git 在工具调用前被拒；`claude-settings.json` 拷成项目 `.claude/settings.json`（已有则合并 hooks 段）。只对 Claude Code 生效，git 钩子仍是底线 |
| `hooks/pre-commit` + `install-git-hooks.sh` | L1 | 主 checkout 提交硬拦（hub 只作只读镜像）+ 与 pre-push 同批安装；保留本机既有钩子为 `.local` 链式调用 |
| `ci.yml.template` | L4 | changes job 骨架 + concurrency + 门禁语义（执行 job 填空） |
| `AGENTS-conventions.md` | 规约载体 | 并进新项目 AGENTS.md/CLAUDE.md 的约定节模板（散文件无人读） |
| `tests/test_agent_guard.sh`、`tests/test_conflicts.sh` | 自检 | 编辑时拦截 54 例 / 冲突雷达 9 例行为回归（临时仓真跑，含 fail-open、暂存重命名、读取失败披露等边界）；分支名自动读 `session-wt.sh` 的参数层（可用 `SL_TEST_DEV` / `SL_TEST_MIRROR` 覆盖） |
| `scripts/verify-install.sh` | 自检 | 在临时裸仓真实驱动 L1/L3/L5 机制，输出 PASS/FAIL/SKIP（31 项本地可验 + 3 项需真实环境；`--drill` 可自动验单调前进闸）。本仓自身不挂 GitHub 托管 workflow（托管分钟受限）——建议在你自己的 CI 里跑它，见 `ci.yml.template` 末尾的三步推荐 |

---

## 让 agent 安装：提示词模板

**一句话版**（本 README 已自解释）：

> 照 `gh repo clone snowspruce/sevenlocks` 拿到的模板仓 README，把 SevenLocks 安装到本仓库：
> 严格执行顶部「文件放置规则」（溶解式），按「落地步骤」走完，验证清单全过后报告。

**完整版**（带硬约束，防跑偏）：

> 把 SevenLocks（七闸）体系安装到本仓库，细节以模板仓文档为准：
> 1. 取模板：`gh repo clone snowspruce/sevenlocks /tmp/sevenlocks-tpl`（公开仓；克隆到 /tmp，勿放进本仓库）
> 2. 先读其 README 顶部「文件放置规则」与「落地步骤」，再读 SEVEN_LOCKS.md「适用边界」自检——若本项目是 PR 流程+部署全在 CI，停止并报告应改用平台能力，不要自建
> 3. 溶解式安装（去向与约束严格按放置规则表）：scripts/ 七件（session-wt / push-mine / deploy-skeleton→deploy.sh / deploy_watchdog / install-git-hooks / **agent-guard.py** / verify-install.sh）+ `tests/` 两件 + `hooks/` 三件（pre-commit/pre-merge-commit/pre-push）→ 本仓库 `scripts/`（hooks/ 三件放 scripts/hooks/）；**claude-settings.json → `.claude/settings.json`（已有则只合并 `hooks.PreToolUse` 段）并与 guard 一起提交进 git**；装完跑 `scripts/install-git-hooks.sh`，**只改各文件「参数层」注释块**（开发分支名/镜像分支（无则置 ""）/锁与公告路径（用本项目名）/gh 仓 slug/**gh 账号**（仓库属另一账号时必填，如 some-bot-account，否则 CI 门禁 404 永拒）/接线清单/CI 等待上限），通用逻辑零改动、保留 `sevenlocks-v<n>` 标记；ci.yml.template → 填占位符存为 `.github/workflows/ci.yml`；AGENTS-conventions.md 内容**并入**本仓库根 AGENTS.md/CLAUDE.md（占位符替换、放靠前）；README 与 SEVEN_LOCKS 不拷入
> 4. 服务部署定制段：服务器/staging 路径/服务清单/切换原语/健康端点由项目负责人提供——未提供前完成 L5 通用段安装、deploy_services 留显式 TODO，报告里列出待提供清单
> 5. 验证：按 README「验证清单」逐项执行并记录输出（已装层必测，未装层写明原因）
> 6. 报告：放置文件清单 / 参数层适配摘要 / 验证结果 / 待人工提供的实施参数清单，并按 README「无法写进通用代码的项目侧设置」逐项打勾（未做的写明原因）
>
> 约束：不改通用逻辑（发现通用段 bug 停下报告，升级走上游）；规约并入而非拷散文件；完成后任何会话都应能 `session-wt start` 起步。

---

## 落地步骤

1. **自检**（5 分钟）：对照 SEVEN_LOCKS.md「适用边界」——PR 流程 + 部署全在 CI 的项目用
   平台现成能力，不要自建。
2. **复制通用件**（半天）：`session-wt.sh` / `push-mine.sh` / `deploy-skeleton.sh` /
   `deploy_watchdog.sh` / `install-git-hooks.sh` / `agent-guard.py` → 新项目 `scripts/`
   （`deploy-skeleton.sh` 改名 `deploy.sh`），`hooks/` 三件 → `scripts/hooks/`，
   `claude-settings.json` → `.claude/settings.json`（已有则只合并 `hooks` 段）；每个文件只改
   **参数层注释块**
   （分支名/镜像分支/锁与公告路径/**SL_SELF_RE（要与部署脚本文件名一致）**/仓 slug/接线清单/
   服务目标），通用逻辑零改动。
3. **CI**（~1 小时）：`ci.yml.template` → `.github/workflows/ci.yml`，填执行 job 与目录
   正则映射；runner 自托管则配 `.env` PATH（多实例同步规约）。
4. **规约 + 硬拦**（~15 分钟）：`AGENTS-conventions.md` 内容并进项目根 AGENTS.md/CLAUDE.md，
   占位符替换；放在文件**靠前位置**（会话必读区）。随后跑
   `./scripts/install-git-hooks.sh`——装 pre-commit（主 checkout 禁提交）、
   pre-merge-commit（`git merge` 绕过 pre-commit 的同判据补充）与 pre-push
   （落后/改写历史拒绝）；本机既有同名钩子会被保留为 `<hook>.local` 链式调用。
   `core.hooksPath` 指向跨仓共享目录时默认拒绝（确认可接受再 `SL_ALLOW_SHARED_HOOKS=1`）。
5. **定制**（每服务 ~300 行）：按 `deploy-skeleton.sh` 文末骨架实现 `deploy_<svc>()`
   ——staging 全预备 → 预检 → 原子切换（venv 蓝绿 / mv / rename 交换三选一）→ 健康检查
   → 回滚。**第一个小心点：rsync --delete 排除表**（server-local 文件全靠它活着）。
6. **验证**：先跑 `bash scripts/verify-install.sh`——它会自动验 31 条本地可测项
   （worktree 全链/clean 守卫/孤儿回收/公告/push-mine/哨兵/锁自愈/部署全链/历史留痕/
   prune/main 保鲜/hub 提交守卫/gc-dirs/备份副本/中断部署可见与不误报/源文件可执行位/
   agent-guard（hub 编辑与整树 git 拒绝 + 接线 fail-open）/conflicts（交集与无交集）/
   adopt（含目录/跨仓/路径穿越/脏 push/交错 pid/过期备份）），
   输出 `PASS/FAIL/SKIP`；**全 PASS 后再按下方清单人工补 3 条需真实环境的项**
   （CI 路径过滤、红 CI 硬拦、单调前进闸）。verify 只证通用层机制，**不证**你的服务部署段、
   真实 CI job、服务器连通——那些必须真部署验。
7. **治理**：通用层改 bug 回上游（上游项目或本包）再各项目同步；落地完成度对照
   SEVEN_LOCKS.md checklist 声明，缺层写明原因。

---

## 升级到新版

模板仓按版本打了 tag（`v1.16` / `v1.17` / `v1.18` …）。**不要整文件覆盖**——项目副本 =
模板文件 + 本地参数层，覆盖会丢分支名 / 锁与公告路径 / 仓 slug / gh 账号 / 接线清单。

```bash
git clone -q snowspruce/sevenlocks /tmp/sl && cd /tmp/sl
git diff --name-status v1.17 v1.18      # 换成「你的当前版本 → 目标版本」
```

（v1.17→v1.18 只动 `session-wt.sh`、`verify-install.sh`、新增 `agent-guard.py` /
`claude-settings.json` / `tests/` 两件、文档；`hooks/`、`push-mine.sh`、`deploy-*` 未变 →
不用重装钩子。）

1. **纯新增**：`agent-guard.py` → `scripts/`；`claude-settings.json` → `.claude/settings.json`
   （已有则只合并 `hooks.PreToolUse` 段）；`tests/` 两件 → `scripts/tests/`。
2. **有参数层的脚本**三方合并（`ours`=项目副本、`base`=当前版本、`theirs`=目标版本）：
   ```bash
   git merge-file -p scripts/session-wt.sh \
     <(git -C /tmp/sl show v1.17:scripts/session-wt.sh) \
     <(git -C /tmp/sl show v1.18:scripts/session-wt.sh) > /tmp/session-wt.new
   ```
   冲突只出现在「模板改了默认值、项目也改过」的参数行（v1.18 是 `SL_WT_ROOT` 一行）——
   保留项目值 + 采用新写法：`SL_WT_ROOT="${SL_WT_ROOT:-/你的路径}"`。
   `verify-install.sh` 可整体拷新，但**它自身带一组参数替换对（`sub()`）**：项目改过参数
   时要把这些对改成项目自己的值；不改会首跑即报
   「参数化失败：找不到 'SL_DEV_BRANCH="kewang"'（模板与 verify 漂移）」——这是漂移检测，
   不是 bug。
3. **文档**：`AGENTS-conventions.md` 的新增节**手工并入**项目 AGENTS.md（整文件覆盖会抹掉
   项目自己的约定）；`README.md` / `SEVEN_LOCKS.md` 不拷。
4. **验证**（在项目里跑，期望值随版本变）：
   ```bash
   ./scripts/install-git-hooks.sh --check    # 钩子未变=OK；有变更再安装
   bash scripts/verify-install.sh            # v1.18：31 PASS / 0 FAIL / 3 SKIP
   bash scripts/tests/test_agent_guard.sh    # 54 PASS
   bash scripts/tests/test_conflicts.sh      # 9 PASS（自动读参数层的分支名；可用 SL_TEST_DEV/SL_TEST_MIRROR 覆盖）
   ```
5. **收尾**：guard 与 `.claude/settings.json` **提交进 git**（否则 worktree 会话没有该文件，
   守卫不生效）；老 `<SL_WT_ROOT>/wt-*` rebase 到新提交；CI 按 `ci.yml.template` 末尾注释补
   三步（verify + 两套回归）。

升级完成的判据：各脚本头部的 `sevenlocks-v<n>` 等于目标版本（不一致 = 漏合），且上面四条
验证全绿。

---

## 验证清单

- [ ] **全局锁**：两终端同时 `deploy.sh`，第二个出现「排队等待中…」而非互踩
- [ ] **锁自愈**：伪造 `/tmp/<project>-deploy.lock`（info 写死进程 pid）再部署，看到
      「发现过期部署锁，自动清理」
- [ ] **worktree 全链**：start → 改文件 → commit（pathspec）→ push → clean；
      clean 对脏 worktree 拒绝并披露内容
- [ ] **镜像同步**（若有）：push 后 origin/<MIRROR> == origin/<DEV_BRANCH>；
      且镜像分支不触发 CI run
- [ ] **门禁分级**：造红 CI + `DEPLOY_ASSUME_YES=1` → 硬拦；`SKIP_CI_CHECK=1` ×
      `DEPLOY_ASSUME_YES=1` → 要求 `CI_SKIP_CONFIRMED=1`。（造红：workflow 只挂 DEV
      push+PR 时，推探针分支不产生 run——探针提交推分支+开草稿 PR 造红、验完即关；
      非 DEV 分支的 `DEPLOY_REF` 会被「HEAD 已推」防线先拦，单测 CI 门禁需配
      `SKIP_GIT_CHECK=1`）
- [ ] **单调前进闸**：`DEPLOY_REF=<旧提交>` 部署 → 拒绝并提示 `DEPLOY_ALLOW_ROLLBACK=1`；
      **区间摘要为空 = 版本戳解析未适配（闸门静默 no-op），当场停**（坑 16）
- [ ] **孤儿回收**：`git branch wt/x origin/<DEV_BRANCH>` 后手删 `/tmp/wt-x` → 下次
      start 输出「回收: 孤儿分支 wt/x」；造一个未吸收孤儿 → 只提醒不删
- [ ] **会话公告**：`echo "until=20991231" > /tmp/<project>-session-notice.txt` + 正文 →
      start 与 deploy 入口都打印；改 until 为昨天 → 不再打印
- [ ] **CI 路径过滤**：只改单目录 push → 其余 job skipped 且 run 结论 success（部署
      门禁放行）

- [ ] **内层哨兵**（v1.6）：在仓库根（非隔离树）执行 `DEPLOY_IN_WORKTREE=1 ./scripts/deploy.sh <目标>`
      → 应**立即拒绝**（哨兵缺失/nonce 不匹配）；正常 `./scripts/deploy.sh <目标>` 能进内层
      （日志见「内层隔离重入」且不再报哨兵）。若看到「按旧外层过渡放行」，说明外层脚本
      还是旧版——`git pull` 后该提示应消失
- [ ] **部署历史留痕**：任一次部署后 `tail -2 <SL_HISTORY_LOG>`（默认
      `/tmp/<project>-deploy-history.log`）→ START/END 配对，END 含 `rc/dur/lock`，
      **失败行另带 `reason=`（最后一条错误摘要，归因不必翻会话日志）**；
      排队超时应出现 `TIMEOUT` 行；SIGKILL 场景只剩 START（无 END）= 判读口径里的硬杀形态
- [ ] **非交互守卫**：`./scripts/deploy.sh <目标> </dev/null`（无 stdin 且未设
      `DEPLOY_ASSUME_YES=1`）→ 应**明确报错**「非交互环境…请显式 DEPLOY_ASSUME_YES=1」，
      而不是记成「已取消」混入失败统计
- [ ] **hub 提交守卫**（v1.14）：装钩子后，在主 checkout 直接 `git commit` → 应**拒绝**并
      给出 `session-wt start` 迁移指令；`git merge --no-ff` 也应被拒（pre-merge-commit）；
      在 `/tmp/wt-<name>` 里提交 → 放行；`SL_ALLOW_HUB_COMMIT=1 git commit` → 放行。
      本机原有 pre-commit 应变成 `pre-commit.local` 且仍被执行（链式）
- [ ] **残留目录回收**（v1.14）：在 `<SL_WT_ROOT>`（默认 `/tmp`）下 `mkdir wt-junk`（无
      `.git`）→ `session-wt gc-dirs` 列出但**不删**；`--yes` 后删除；已注册的 worktree 与
      带 `.git` 的目录不受影响（判据要求目录名 `wt-*`）
- [ ] **备份副本**（v1.14）：本地有 `backup/*` 分支时跑 `session-wt replicate` →
      `git ls-remote origin 'refs/backup/*'` 出现同 SHA；重跑输出「已最新」；
      取回命令能还原分支
- [ ] **中断部署可见**（v1.14）：向 `<SL_HISTORY_LOG>` 追加一条旧时间、死 pid 的 `START`
      （无 END）→ 下一次 `deploy.sh` 启动打印「上一次部署未正常结束」并带 pid/年龄；正常
      START/END 配对的部署不报
- [ ] **编辑时拦截**（v1.18）：在 Claude Code 里对主 checkout 的文件发一次 Edit → 应被拒
      并给出 worktree/adopt 指令；worktree 里的 Edit 放行；`git commit --no-verify`、
      `SKIP_PREPUSH_CHECK=1 git push`、`DEPLOY_IN_WORKTREE=1 ./scripts/deploy.sh` 都被拒；
      启动期 `SL_ALLOW_HUB_EDIT=1` 可放行 hub 编辑（只对 Claude Code 生效，其他 agent 靠 git 钩子）
- [ ] **冲突雷达**（v1.18）：两个 session worktree 各改同一个文件（一个不提交、另一个提交）→
      `session-wt conflicts <我>` 报「与会话 X 同时改到 N 个文件」；只改各自独有的文件 → 报
      「无跨会话文件重叠」
- [ ] **混着别人的改动时**（v1.16）：在主 checkout 改一个文件 + 建一个未跟踪文件 →
      `session-wt adopt <name> -- <这两个路径>` → worktree 里能看到改动与文件，**主 checkout
      两处改动都还在**（命令只复制不删除）；随后可在 worktree 里 pathspec 提交

---

版本历史见 [`CHANGELOG.md`](CHANGELOG.md)。

---

## License

[MIT](LICENSE)。脚本无第三方依赖（bash + python3 标准库）；文档可自由引用，注明出处即可。
