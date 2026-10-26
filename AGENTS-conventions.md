# AGENTS.md 约定节模板（AI 会话的规约载体——拷进新项目根目录的 AGENTS.md / CLAUDE.md）

> 这是整套体系的「操作系统加载项」：所有 AI 会话每次开工必读。漏了它，工具再全也会被
> 会话绕过。占位符 `<…>` 按项目替换；斜体处按需删改。

---

## 多会话并行：编码一律会话 worktree 起步，主 checkout 只作 hub

- 本仓库由多个并行 AI 会话共同开发。**任何编码前先 `./scripts/session-wt.sh start <name>`**，
  在 `/tmp/wt-<name>` + 分支 `wt/<name>` 里干活；主 checkout 只作 hub（持 `<DEV_BRANCH>` +
  共享依赖），**绝不直接编辑**。此规则由 `scripts/hooks/pre-commit` **硬拦**（在 hub 提交
  直接失败）；确认本机已装：`./scripts/install-git-hooks.sh`（重复执行即更新）。
- 提交一律 pathspec：`git commit -m "msg" -- <paths>`，永远不用 `git add -A` / `git add .`
  ——共享空间的暂存区不属于你。
- **开工先看谁在同改同一文件**：`./scripts/session-wt.sh conflicts <name>`——把你的未提交
  改动 + 未推送提交与每个其他 worktree（含 hub）的改动集求交集，并提示 origin 已改过的
  文件（rebase 预警）。只读、不拦操作（仅 fetch 刷新 origin 引用）。
- 推送：`./scripts/session-wt.sh push <name>`（整分支 rebase 推送）；单提交重放用
  `./scripts/push-mine.sh`。**绝不直推 `<MIRROR_BRANCH>`**（生产镜像，由工具自动 FF 同步）。
- 会话收尾：`./scripts/session-wt.sh clean <name>`（有未推/脏改动会拒绝并披露内容）。
- 收口后把本地 `backup/*`、`archive/*` 推远端副本：`./scripts/session-wt.sh replicate`
  （只在本机 = 机器丢失即全丢）。/tmp 残留体检：`./scripts/session-wt.sh audit`。

## 编辑时拦截（Claude Code 增强层，可选装）

- 仓库 `.claude/settings.json` 挂 `PreToolUse` → `scripts/agent-guard.py`：改 hub 里的文件、
  hub 里 `git commit`、`commit`/`push --no-verify`、`SKIP_PREPUSH_CHECK=1` 的 push、外部预设
  `DEPLOY_IN_WORKTREE=1`、hub 里整树覆盖型 git（`checkout -f`/`switch -f`/`reset --hard`/
  `clean -f`/`stash`）都会在**工具调用前**被拒（只在装有本体系的仓库内生效）。
- **只对 Claude Code 生效**，是增强层不是替代：ZCode / Codex / 手工终端的底线仍是 git 钩子。
- 逃生舱（启动期）：`SL_ALLOW_HUB_EDIT=1` / `SL_ALLOW_HUB_DESTRUCTIVE=1` / `SL_GUARD_BYPASS=1`；
  命令行内联：`SL_ALLOW_HUB_COMMIT=1` / `SL_ALLOW_NO_VERIFY=1` / `SL_ALLOW_SKIP_PREPUSH=1`。
- **落地要求（项目侧，模板不代劳）**：`scripts/agent-guard.py` 与 `.claude/settings.json`
  必须**提交进 git**（只改 hub 工作区 → 各会话 worktree 看不到 = 不生效）；项目已有
  `.claude/settings.json` 时只合并 `hooks.PreToolUse` 段（该文件还承载 permissions/env）；
  `python3` 缺失时钩子以非 2 退出码放行（守卫静默失效，别当成写保护）。

## 现场混着别人的改动时（多会话共用主 checkout 的常见形态）

- 主 checkout 里出现**不是你改的**文件：不提交、不 `git stash -u`（全量 stash 会摘走别人的
  在制品）、不 `git checkout --` / `git restore`（会抹掉别人的改动）。
- 提交自己的改动：`./scripts/session-wt.sh adopt <name> -- <你的路径…>`——只把这些 paths 的
  改动**复制**进 `/tmp/wt-<name>`，主 checkout 原样保留；随后在 worktree 里
  `git add -- <路径…>` → `git commit` → `./scripts/session-wt.sh push <name>`。
- **部署不读本地工作区**：`deploy.sh` 默认从 `origin/<DEV_BRANCH>` 检出隔离树，日志会写明
  「本地未提交改动不参与本次部署」。**不要为了让部署生效去提交不属于你的文件**；只需保证
  你的提交已 push。
- 无人值守部署直接 `DEPLOY_ASSUME_YES=1 ./scripts/deploy.sh <目标>`（红 CI 仍硬拦）；
  只有「归属不明且确实会影响生产」才停下来问人。

## 部署（唯一入口）

- `./scripts/deploy.sh <服务参数>`——默认从干净隔离 worktree 检出 `origin/<DEV_BRANCH>` 部署，
  带全局排队锁（撞锁=排队不是失败）、提交区间确认、单调前进闸（回滚须 `DEPLOY_ALLOW_ROLLBACK=1`）。
- 无人值守（`DEPLOY_ASSUME_YES=1`）红 CI 硬拦；`SKIP_CI_CHECK=1` × 无人值守须再加
  `CI_SKIP_CONFIRMED=1`（零防线部署二次确认）。
- 部署等待 CI 结论上限 `CI_WAIT_TIMEOUT`（默认 900s）。
- *（若 self-hosted runner）CI runner 在本机：状态 `launchctl list | grep actions.runner`
  （或 systemctl），日志 `/tmp/actions-runner*.out`；工具链 PATH 在 runner 的 `.env`
  （多实例须同步改）；**勿在服务器上重启 runner**（曾致 OOM 全站假死）。*

## 会话公告

- `cat /tmp/<project>-session-notice.txt`（首行 `until=YYYYMMDD`，过期自弃）——收口/流程
  变更等跨会话通知位；`session-wt start/list` 与 `deploy.sh` 入口会自动打印。

## 纪律（防事故复发的根）

- 不碰别人的半成品：别的会话的 worktree / 脏文件 / stash 一律不动，有疑问先问人。
- stash 是代保管不是代决策：收口保全的在制品用 `git stash show -p stash@{0}` 查看、
  确认后 `git stash pop` 取回。
- 改通用脚本（session-wt / push-mine / deploy 通用段）须同步上游模板并保留
  `sevenlocks-v<n>` 版本标记——单项目魔改 = 防护语义分叉腐化。
