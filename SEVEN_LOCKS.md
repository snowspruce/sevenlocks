# SevenLocks（七闸）——多 AI 会话并行开发·提交·部署的七层防护体系

> 可移植参考架构。源自一个真实生产仓库（2026-10 定型），该仓库由 1 名工程师 + 5~10 个并行 AI
> agent 会话（ZCode/Claude Code 等）共同开发，单人单部署机，直推分支（无 PR 流程）。
> 本文档不依赖原仓库上下文：每层给出「防什么事故 → 核心机制 → 可抄精要」，供其他项目复制。
> 完整脚本用法见本仓 `README.md`。

## 一句话定位

**该并行的层（编辑/提交/推送/CI）彻底并行，必须串行的点（部署/评估）显式设闸——
用结构消灭多会话互相踩踏，而不是靠每个会话的记性和自觉。**

## 适用边界（先自检）

适用：
- 1~3 名工程师 + 多个并行 AI 会话共用一个仓库
- 部署从固定的一台机器发起（本机或跳板机）
- 直推分支文化（不走 PR），或 PR 但合并后仍有本地部署动作
- 单部署目标（或少量），部署互踩后果严重

不适用（直接用平台现成能力，见 §平台替代映射）：
- 多人团队强协作（用 PR + required checks + Merge Queue）
- 部署目标在 CI 内完成（用 CI 的并发组/环境锁）
- 开源仓库（本机 self-hosted runner 会被任意 PR 执行代码，禁止）

## 为什么自建：三条约束（诚实声明）

这套体系的**形状**就是成熟 CI/CD 平台的标准能力面；我们手搓是因为：
1. 部署从本机发起（rsync+ssh 到服务器），不在 CI 里——CI 平台的部署锁管不到；
2. 直推分支文化，无 PR 门禁可挂；
3. 多 AI 会话是生态新事物，现有平台没有「会话工作区隔离/会话间公告」概念。

若你的项目不满足这三条，逐条用平台功能替换（见 §平台替代映射），不必自建。

---

## 七层总览

| 层 | 防什么事故 | 核心机制 | 形态 |
|---|---|---|---|
| L1 编辑层 | 并行会话同文件互覆 / `git restore` 误伤他人半成品 | 会话 worktree 隔离，主 checkout 只作 hub | 工具脚本 + 约定 |
| L2 提交层 | 提交裹挟他人未完成改动（暂存区污染） | pathspec 提交 + 会话分支 | 约定 |
| L3 推送层 | 分叉互相顶掉 / 直推生产镜像分支 | 单提交幂等重放 + rebase 推送 + 拒推 main | 工具脚本 |
| L4 CI 层 | 红测试无人看 / 无关提交烧 CI 分钟 / 无人值守带病上线 | job 级路径过滤 + 门禁分级（无人值守红 CI 硬拦）+ 本地 runner 池 + 本地依赖缓存 | workflow + 门禁钩子 |
| L5 部署层 | 并发部署互踩 / 回滚踩掉他人修复 / 带红上线 / **部署期间服务中断** | **全局排队锁** + 隔离 worktree 部署树 + 单调前进闸 + **staging 预备+原子切换（零中断）** + 组合逃生舱 | 部署脚本 |
| L6 评估层 | 评估结论混入不同代码版本 | 全局串行锁 + 部署版本前后快照标注 | 代码内锁 |
| L7 运维卫生层 | 积压腐化 / 会话失联 / 半成品无家可归 | 保全式收口 + 入口公告 + 独立审查惯例 | runbook + 惯例 |

**落地顺序建议**（价值密度从高到低）：
L5 全局锁（半天，立即消灭部署互踩）→ L1/L3 worktree+推送工具（半天，消灭提交层事故）
→ L4 门禁分级（半天）→ L7 公告+收口 runbook（两小时）→ L2 约定（零成本，写进 AGENTS.md）
→ L6（有评估套件才需要）→ 依赖克隆缓存（有 npm 级大依赖才值得）。

---

## L1 编辑层：会话 worktree 隔离

**事故根源**：多个会话共用一个工作区 + 一个 index——历史上 12 类事故（同文件覆盖、
`git add -A` 裹挟、`git restore` 抹掉在制品、stash 混归属）全部源于此。

**机制**：
- 主 checkout 只作 hub（持默认分支 + node_modules 等共享资源），**不再直接编辑**；
- 每个会话开工：`session-wt start <name>` → 建 `/tmp/wt-<name>` + 分支 `wt/<name>`
  （默认基于 `origin/<default>`），自动软链共享 node_modules / venv、拷贝本地 env 文件；
- 完工：`session-wt push <name>`（fetch+rebase+推整条分支）；清理：`session-wt clean`
  （有未推提交或脏文件时拒绝，`--force` 强清）。

**关键设计**：
- worktree 接线（node_modules 软链）让新会话零等待可用——否则每个会话 npm ci 十分钟，规约必死；
- `list` 子命令随时看各会话 ahead/dirty（跨会话可见性）；>3 天未动的 worktree 审计提醒；
- **防堆积**：会话收尾 `clean`（未推/脏文件拒清+披露）；每次 `start` 顺带**孤儿分支安全回收**
  ——worktree 载体已失（目录不存在**或**被清成空壳）**且**内容已被上游吸收（`git cherry`
  patch-id 判定无 `+`）的会话分支自动删（先 `worktree prune` 清失效注册），未吸收的孤儿只
  提醒不删（可能藏着未推工作，归属判断留给人工——自动删除永远不允许碰到可能有半成品的
  分支）；故意的全自动 GC 只做这条无损路径；
- **/tmp 的真实语义（2026-10-16 拍板：保持 /tmp + 口径修正）**：macOS 对 /tmp 是**定期清理
  而非重启自清**——3 天未访问的 worktree 会被清成空壳（目录在、内容空、.git 没了；当日
  实证 8 个）。后果：已提交内容无损（分支在，孤儿回收兜底，载体判定含空壳感知）；**闲置
  会话的未提交文件会被系统抹掉**（收口保全纪律兜底）。故 worktree 里的在制品要么及时
  commit，要么 3 天内回来动它；载体存活判定一律以「目录在且有 .git」为准；
- hub 保鲜：每次 `start` 时若 hub HEAD==默认分支则 ff-only 快进（落后不阻塞，机会性）；
- **hub 直编从规约变硬拦（2026-10-22）**：`scripts/hooks/pre-commit` 判 `git-dir ==
  git-common-dir`——主 checkout 上 `git commit` 直接失败并打印迁移指令（`session-wt start` +
  **只导出自己的路径**：`git diff -- <paths> > /tmp/mine.patch` 后在 worktree `git apply`；
  共享 hub 上全量 `git stash -u` 会摘走别人的在制品）；链接 worktree 放行；
  `SL_ALLOW_HUB_COMMIT=1` 是收口/rebase 的显式逃生舱。`git merge` 走 `pre-merge-commit`
  同判据（实测 `--no-ff` 绕过 pre-commit）；`cherry-pick/revert/rebase` **不在覆盖内**
  （显式历史操作，且 hub 的重写会被 pre-push 的落后/非快进检查二次拦截）。
  安装器 `scripts/install-git-hooks.sh` 把钩子**复制**进 hooks 目录（软链会在 worktree
  删除后变断链），并把本机既有同名钩子保留为 `<hook>.local` 链式调用——绝不静默顶掉
  （本机 `core.hooksPath` 已指向 `.git/hooks`，那里有现役 pre-commit）；`pre-push` 链式
  调用会**回放同一份 stdin ref 列表**（否则 git-lfs 类钩子拿到 EOF 静默失效）。
  `core.hooksPath` 指向跨仓共享目录时安装器默认拒绝（`SL_ALLOW_SHARED_HOOKS=1` 放行）；
  `start` 会自检「缺失/陈旧」并提示；
- **主 checkout 混着别人改动时的安全出口（2026-10-23）**：硬拦之后会话会被「不敢提交
  （会带上别人的文件）、也不该全量 stash」卡住而停下问人。`session-wt adopt <name> --
  <paths…>` 把指定 paths 的**已跟踪 diff（含暂存区）+ 未跟踪文件**复制进 worktree，主
  checkout 一个字节不删；随后在 worktree 里 pathspec 提交、push、部署。边界（v1.17 审查
  收口）：目录参数按**文件逐个枚举**（不是「目录 tracked 就整包跳过」，否则目录内新文件
  静默漏拷）；重命名自动把旧/新两侧都纳入；目标 worktree 必须属于本仓库且检出
  `wt/<name>`（`/tmp/wt-*` 是全局命名空间，防跨仓误写）；拒绝 `.`/`..`/pathspec magic；
  `push` 前有未提交改动直接拒绝（原「无领先提交」会假成功）。配套语义必须讲清：
  **部署读 `origin/<dev>`，本地未提交改动不参与**——不存在「必须先把别人的改动提交了
  才能部署」；无人值守会话直接 `DEPLOY_ASSUME_YES=1`，只有归属确实影响生产才问人。
- **编辑时拦截（2026-10-24，增强层）**：git 钩子只在 commit/push 时失败——那时会话已投入
  一整轮工具调用。仓库 `.claude/settings.json` 挂 `PreToolUse` 钩子 `scripts/agent-guard.py`，
  在**工具调用前**拒：改 hub 里的文件（Edit/Write/MultiEdit/NotebookEdit，路径 realpath 后判
  `git-dir==git-common-dir`）、hub 里 `git commit`、`commit`/`push --no-verify`、
  `SKIP_PREPUSH_CHECK=1` 的 push、外部预设 `DEPLOY_IN_WORKTREE=1`、hub 里整树覆盖型 git
  （`checkout -f` / `checkout -- .` / `switch -f` / `restore .` / `reset --hard` / `clean -f` /
  `stash`）。只在装有 SevenLocks 的仓库内生效（会话根有 `scripts/session-wt.sh`），避免在
  submodule / 第三方仓里误拦。命令解析跟踪
  `cd` / `-C` / `--git-dir` / env 前缀 / heredoc；判不准或内部异常一律放行（fail-open）。
  **定位是增强层**：只对 Claude Code 生效，ZCode / Codex / 手工终端的底线仍是 git 钩子。
  落地要求（项目侧）：guard 与 `.claude/settings.json` 必须进 git（否则 worktree 会话看不到）；
  项目已有 settings 时只合并 `hooks.PreToolUse` 段；`python3` 缺失时钩子以非 2 退出码放行
  （fail-open，别当成写保护）。
- **跨会话冲突雷达（2026-10-24）**：`session-wt conflicts <name>`——把「我的未提交改动 +
  未推送提交」与每个其他 worktree（含 hub）的改动集求交集，并报 origin 在分支点之后改过的
  同文件（rebase 预警）。只读、不拦操作（仅 fetch 刷新 origin 引用；status 用
  `GIT_OPTIONAL_LOCKS=0` 不刷新别人的 index）：让「两人同改一个文件」在动手时就可见，
  而不是在 push/rebase 时才发现。
- **审计盲区收口（2026-10-22）**：原先的审计只看得见 git 注册的 worktree 与 `wt/` 分支，
  实测漏掉 17 个无 `.git` 的 /tmp 临时目录（115MB）、hub 的 54 个脏文件、只在单机的
  backup 分支、以及被中断的部署。`session-wt audit`（start 也跑）现在四类全查；清理分别走
  `gc-dirs`（无 `.git` + 未注册 + 够老，默认 dry-run）、`replicate`（备份推 `refs/backup/*`）、
  `deploy_watchdog`（START 无 END 报出）；
- 命名校验：禁止 `.`/`..`/斜杠/全角字符（worktree 名进路径，防注入）。

**最小实现**：`git worktree add -b wt/<name> /tmp/wt-<name> origin/<default>` + 接线 + 四个子命令。
约定写进仓库根的 AGENTS.md/CLAUDE.md（AI 会话每次必读），**开头第一句就是「编码一律 worktree 起步」**。

## L2 提交层：我的提交只含我的文件

- 会话分支上天然满足（worktree 里只有我的改动）；
- 万一在 hub 上操作（禁令之外）：**提交一律 pathspec**——`git commit -m "msg" -- <paths>`，
  永远不用 `git add -A` / `git add .`（共享工作区的暂存区不属于你）；
- 事故后取证法：`git cherry` / `patch-id` 判定重复提交，blob 对比判内容级差异。

## L3 推送层：分叉是常态，不是事故

直推文化下，两会话同时 `push` 必然分叉。把「人肉记忆 rebase 配方」工具化：

**push-mine（单提交重放）**——在临时 worktree 里只重放自己的一个提交：
```
幂等双检：
  git merge-base --is-ancestor <sha> origin/<branch>  → 已在，跳过
  git cherry origin/<branch> <sha> <sha>^            → patch-id 已被上游吸收，跳过
重放：git rebase --onto origin/<branch> <sha>^ <sha> → push
冲突：保留 worktree 现场 + 打印手工续接指引（绝不替用户决策）
守卫：目标为 main（生产镜像）直接拒绝
```

**session-wt push（整分支推送）**：fetch → rebase onto `origin/<default>` → push。
rebase 冲突由会话自己解（自己的提交自己最清楚）。

**main = 生产镜像，永不直推**：两会话工具均硬拒 `BRANCH=main`；镜像由推送工具**自动 FF 同步**
（push 开发分支成功后顺手 `git push origin HEAD:main`）——远端默认分支滞后会让新克隆拿旧
代码，靠人记着同步必腐化。非 FF（main 出现独有提交）天然被拒、只提醒不强推，失败不阻塞
推送主流程。⚠️ 配套：**main 必须从 CI 的 push 触发分支里移除**——镜像提交在开发分支已有
run，push 触发 main 会原样重跑一遍，纯浪费且挤占 runner（自动化首日实测）。

## L4 CI 层：门禁分级 + 并行池 + 本地缓存

**路径过滤（job 级，不是 workflow 级）**：
```
changes job: git diff --name-only <push.before> <sha> → 各目录命中输出
执行 job: needs: changes + if: needs.changes.outputs.<k> == 'true'
兜底全跑：非 push 事件 / 基线缺失 / 强推 / 改 ci.yml 自身
```
⚠️ **不要用 workflow 级 `on.push.paths`**：无关提交会整个不触发 → 部署门禁查无 run →
被自己的门禁拦死。skipped job 的 run 结论=success，门禁语义不变。

**concurrency：`cancel-in-progress: false`**。同 ref 的 pending run 会被自动淘汰
（cancelled ≠ 失败，是「被新 push 覆盖」）；false 保证长 run 不被高频 push 打断。
部署门禁对 cancelled 的文案要点明「该 run 可能从未执行，换最新 head」。

**门禁分级（部署脚本查 CI 结论时的语义）**：
| 场景 | 有人值守 | 无人值守（ASSUME_YES=1） |
|---|---|---|
| success | 放行 | 放行 |
| 红（completed 非 success） | 警告不拦 | **硬拦** |
| 排队/超时 | 提示 | 提示，**但 runner 进程不在时硬拦**（结论永远不来） |
| SKIP_CI + ASSUME_YES 组合 | — | 须再显式设二次确认变量 |

原则：**未知 ≠ 红**（平台故障期不能全停）；但「结论永远不会来」≠ 未知，必须拦。
所有逃生舱（SKIP_*）都要求危险组合叠加二次显式变量——误用的摩擦力恰好，不影响真急用。

**runner 池与缓存（self-hosted 场景）**：
- ⚠️ **runner 永不与生产同机**（原仓曾 3.6G 服务器跑 CI job → OOM 全站假死一次）；
- 本机/专用机 3 实例并行池：job 级 fan-out，全量 run 串行 ~12min → ~5min；
- launchd/systemd 启动的 runner **无 shell profile**：工具链 PATH 必须写进 runner 的
  `.env` 注入；多实例时 N 份 .env 必须同步改（漂移=同 workflow 随机红绿，极难排查）；
- 依赖缓存用**本地文件系统**（macOS: APFS `cp -c` 克隆 813M 恢复 7 秒；Linux: reflink），
  ⚠️ `actions/cache` 在 self-hosted 仍占 GitHub 计费存储（免费档 500MB 很快爆）；
- 缓存键 = lockfile + package manifest + 工具链版本三合一哈希（防「改 manifest 忘更
  lock」绕过安装校验假绿；工具链升级自动换键）。

## L5 部署层：全局排队锁（体系的皇冠）

**串行点唯一且显式**：部署构建（rsync+构建+切换）全局互斥，排队等待而非失败退出。

**mkdir 原子锁（macOS 无 flock 时的正确写法）**：
```bash
LOCK=/tmp/<project>-deploy.lock
acquire() {
  while :; do
    if mkdir "$LOCK" 2>/dev/null; then            # 原子抢占
      echo "$$|<target>|$(date +%s)" > "$LOCK/info"   # 持有者 pid + 心跳时间戳
      # 写回校验（不可省）：mkdir 成功 ≠ 仍持有——写 info 前锁可能被清理者删掉重建
      grep -q "^$$|" "$LOCK/info" || { rm -rf "$LOCK"; continue; }
      echo "<内层隔离进程pid>" >> "$LOCK/info"    # 多层进程锚定：全部死才可判过期
      return 0
    fi
    holder=$(head -1 "$LOCK/info" 2>/dev/null); pid=${holder%%|*}
    if ! kill -0 "$pid" 2>/dev/null; then         # 持有者已死 → 清理重试（清理失败也 continue）
      # 原子抢占清理权（2026-10-13 加固）：rename 到唯一名——同一时刻只有一个清理者能成功，
      # rm -rf 只删自己的私有副本，闭合「两等待者同清一把死锁 → 双双 mkdir → 双持有者」竞态
      mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -rf "$LOCK.stale.$$" 2>/dev/null || true
      continue
    fi
    sleep 10; waited=$((waited+10))
    # 心跳超时同样检查 info 内全部 pid；排队上限（如 2h）到点 exit 75（区别于部署失败）
  done
}
release() {  # pid 守卫：只删自己的锁
  [ "$(head -1 "$LOCK/info" 2>/dev/null)" = "$$|..." ] && rm -rf "$LOCK" || true
}
trap 'release' EXIT   # bash 3.2 注意：EXIT trap 里 rm 失败要 || true 吞掉
```
**实测语义**：撞锁=排队等待（10s 轮询、每 60s 打印排队提示），不是退出——
多会话同时部署从「互相打架」变成「排成一队」。

**内层标记须防外部预设**：隔离壳调内层用 `DEPLOY_IN_WORKTREE=1` 这类内部标记时，该标记
会让内层跳过锁/隔离/闸——必须让内层可验证调用来源：壳生成一次性 **nonce** 写入 worktree 的
**git admin 目录**（`git rev-parse --git-path deploy-inner`，树内不可见→不脏工作区检查），
经环境变量传入内层比对；哨兵**存在但 nonce 不匹配一律拒绝**（仅「文件存在」会被 `touch`／
陈旧部署树复用绕过），仅完全缺失时对旧外层做一版过渡桥接（父进程直接跑 deploy.sh 脚本、
非 `-c` 内联——复制粘贴命令的 `zsh -c` 形态必须仍被拒）。否则「从源码/日志复制命令」的
外部预设会同时绕过全部防线，比任何文档化逃生舱更彻底。
另：防倒退闸应对**本次部署目标**逐个校验（一次 SSH 批量读版本戳；读取失败须与「全空戳」
区分，无人值守下盲态默认硬拦），且默认隔离路径与直部逃生舱覆盖面必须一致（默认路径弱于
逃生舱=倒挂）。

**隐含假设——部署只从单机发起**：全局锁在发起机的 /tmp，互斥范围=该机全部会话/
checkout；服务器侧只靠 per-服务的切换互斥（flock/原子 mv）。若出现第二部署发起方
（他人机器/服务器侧脚本），需补远程互斥（服务器 mkdir 锁+残留判定——外部项目 deploy
实证此形态）。等待上限环境变量化（DEPLOY_LOCK_WAIT，默认 7200s，防误配须归一化）。

**部署历史留痕**：外层壳每次部署向 `/tmp/<project>-deploy-history.log` 写一对
START/END（时间/pid/目标/rc/时长/锁态），排队超时写 TIMEOUT 行——中断的部署不再零痕迹
（实战动机：一次被中断的部署完成了树同步+重启但健康/版本戳未跑且无任何记录，事后靠
服务器 mtime 反推 40 分钟）。判读口径（实测矩阵）：无 END=SIGKILL 硬杀**或 INT 单发挂起**
（先 pgrep 确认进程不在跑）；END rc=0 但服务无新版本戳=可疑中断（TERM/HUP 下 bash 执行
EXIT trap 但内部 `$?` 恒 0；单发 TERM/HUP 还会残留前台 ssh/rsync 子进程，处置=pgrep 清
残留再放行下个部署）；END rc∉{0,75}=显式失败。

**中断告警闭环（2026-10-22）**：留痕只有人去看才有用——`scripts/deploy_watchdog.sh` 把
「START 无 END」变成主动告警：
- **按 pid 配对** START/END（真实历史里 `SKIP_DEPLOY_LOCK=1` 会交错写入；顺序配对实测在
  247 START/247 END 全配对的文件上仍误报 1 条）；实现用 awk 单遍（O(n)；原每个 END 重写
  整个 open 文件，10k 行实测 39s）；
- 记录 pid 仍存活且 ≤ `SL_WATCHDOG_MAX_AGE`（默认 7200s）→ 正常进行中；**超过上限仍报
  「可能挂起」**（进程活着≠健康：TERM/INT 单发后卡在 ssh/rsync 的形态）；
- 记录 pid 已不在 → 报（**即使另有部署在跑**：外层被杀、内层继续时中断事实仍要被告知；
  原先「有活部署就跳过」会让并发期所有孤儿静默——2026-10-22 CI 实证）；判活排除
  `bash -c '…deploy.sh…'` 这类内联命令（pid 复用 + 子串匹配会掩盖孤儿）；
- START ≥ `SL_WATCHDOG_MIN_AGE`（默认 300s）才报，避免与刚启动的部署抢跑。
`deploy.sh` 在写本次 START 前调用，`session-wt audit/start` 也调用；
`SL_ALERT_CMD` 可接项目既有告警通道。
即「下一次部署或新会话开始」必然看见上一次中断（SIGKILL 无法被 trap，外部检查是唯一出路）。

**销账（2026-10-23 审查 P2 收口）**：SIGKILL 留下的孤儿 START 此前没有任何清除通道——
每次部署/start 永久重报，告警迅速贬值。人工确认无残留传输后显式销账：
`./scripts/deploy_watchdog.sh --ack <pid>...`（复算 open 集校验 pid 确有未关 START，
补一条 `ack=manual` 的 END 行；写错 pid 报 WARN 不污染历史）。告警报告的处置步骤里
带可复制的销账命令。

⚠️ **2026-10-13 两条实证加固（上游 deploy.sh 与模板骨架均已同步）**：
- **读 info 的 pid 一律 `head -1`**：info 第 2 行起追加了内层 pid 后，`cut -d'|' -f1` 会返回
  **多行值**——`ps -p` 与字符串比较全部失配（主过期判据恒判「过期」、release 守卫恒不相等
  =每次隔离部署都留残锁；实测于生产环境复现并修复）。
- **过期清理用 rename 原子抢占**（见上方代码）；`.stale.*/.self.*` 残留由 acquire 入口
  best-effort 清理（>1 天）。`.self.*` 用于「info 首字段是自己」的竞争败战残留。

**隔离部署树**：部署动作默认在临时 worktree 检出 `origin/<default>`（不是本地分支！）：
- 他人工作区未提交改动天然隔离；不被「工作区必须干净」检查卡死；
- TOCTOU 闭合：先拿全局锁、后 fetch——锁内看到的 ref 就是部署的 ref；
- 指定旧 ref 部署时 fail-closed：显式 `DEPLOY_REF=<sha>` 的 fetch 失败**不做本地 stale 兜底**。

**单调前进闸**：部署前对比服务器当前 commit 与待部署 HEAD——服务器上有本次 HEAD 不含的
提交 = 回滚风险 → 拒绝（并行会话从旧 ref 部署会静默踩掉已上线修复）。真要回滚须显式
`DEPLOY_ALLOW_ROLLBACK=1`。

**九道防线全表**（自检清单）：
全局排队锁 / 隔离部署树 / ref fetch fail-closed / 单调前进闸 / 红 CI 无人值守硬拦 /
runner 离线探测 / SKIP×ASSUME 组合二次确认 / 服务器侧切换互斥 + 原子切换 /
部署前「HEAD 已推远端」校验。

### 零中断切换：staging 全预备 + 单原子操作（L5 的另一半）

全局锁解决「谁部署」，零中断切换解决「部署期间用户无感」——两者合起来才是完整部署层。
核心原则一句话：**重活全部离线做，live 只接受一次原子操作**。

**1）构建与切换分离（staging 模式）**：
- rsync、依赖安装（npm install / pip install）、构建、语法校验**全部发生在 staging 目录**，
  live 目录全程跑着旧版本不受触碰；
- 反模式（实战踩过）：rsync --delete 直打 live + 在 live 上 npm install——旧进程全程
  「跑在被换血的目录上」；schema 热读的服务（如 dev 模式 Cube）会在半成品 model 上
  触发重编译，分钟级窗口内报表查询出错；
- staging 内做**切换前预检**（Python 语法/依赖、新 venv 先 import 一次）——半成品
  永远到不了 live。

**2）切换动作 = 三种原子原语（按服务形态选一）**：
| 服务形态 | 原语 | 中断窗口 |
|---|---|---|
| Python（进程持旧依赖跑完） | **venv 蓝绿**：`.venv` 是符号链接，新 venv 完整建好后 `ln -sfn` 换链接 | **真零中断**（旧进程持旧 venv 继续跑，下次启动才用新） |
| 静态/Node 目录 | **同分区 `mv`**（rename 系统调用，亚秒级原子） | 亚秒 |
| 目录+依赖全换（node_modules 等） | **rename 交换**：新树就位后 mv 换名，旧树留 `.prev` 供回滚；node_modules 可硬链接复用 live（未变更文件共享 inode，零拷贝） | 秒级（进程重启间隙） |

**3）失败回滚原生**：切换前备份旧版本（目录 `.prev` / venv 上一版链接），切换后
健康检查（如 60s 就绪窗）不过 → 自动回滚到上一版，不需要重新部署。

**4）诚实口径**：pm2 restart 类服务仍有秒级中断窗口（delete→start 间隙）——
全量重启须显式 `-a`，日常单服务部署走上述原子路径。

**5）关键坑**：staging→live 的 rsync `--delete` 排除表是**单一真相源**，守卫预演与
真实切换必须共用同一份——server-local 文件（crontab 凭据等不在仓库的文件）全靠
排除表活着，被 --delete 误删即监控静默停摆（原仓 12 小时无人发现的实录）。

## L6 评估层：结论必须可归因到代码版本

评估（eval/benchmark）套件若与部署共享生产进程：
- **全局串行锁**（进程内 `asyncio.Lock` / 跨进程文件锁）——所有触发入口（手动/定时/CI）共用一把；
- **版本快照标注**：套件启动时读各服务的部署版本标记，结束再读一遍，不一致 → 结果里
  打 `deploy_mix` 警告字段（「本次运行期间有部署切换，结论混版本」）；
- 评估**有意不并行**：前缀+时间窗聚合类指标会被并发运行互相污染，串行是正确性要求。

## L7 运维卫生层：让体系自我维持

- **保全式收口**（长期并行后 hub/分支积压时的清理仪式）：
  归属分析（patch-id 判定上游已含，**同内容异 SHA 须逐对 diff 裁定**——见坑 21）→
  backup 分支 + git stash（**代保管不代决策**）+ **保全四件套**（2026-10-17 补强：
  tracked 全量 patch（须与工作树互逆可回放）/ **untracked 全量 tar（必须
  `--untracked-files=all` 展开，见坑 20）**/ status 快照 / 归属分类表）→
  **档案落持久位置（家目录备份目录；/tmp 横跨重启不可依赖）** →
  `reset --hard origin/<default>`——**恢复/对齐目标一律 origin 而非本地 HEAD**
  （分叉陈旧线下 checkout HEAD 是往旧恢复；工作树与 HEAD 的"混合 diff"里相当部分
  是「工作树已是 origin 版」的假混合，线级 catch-up 自动消解）。清理时机用自动轮询等窗口：
  无部署进程 / 锁空闲 / 15 分钟无 tracked 文件改动 / tip 稳定。
  **挂起过的收口在执行日必须重验**（fetch → 重跑 status/diff → 与档案快照对比，
  漂移先重新归档再动手——否则错杀保全后新进现场的改动）。
- **会话公告**：`/tmp/<project>-session-notice.txt`（首行 `until=YYYYMMDD` 自过期），
  在部署脚本入口和 worktree 工具里打印——向所有并行会话广播一次性事实
  （收口事件/规则变更），解决「会话间无法互相通知」。
- **备份必须有远端副本（2026-10-22）**：`backup/*`、`archive/*` 是收口的最后保险，但实测
  全部只在单机（机器丢失即全丢）。`session-wt replicate` 推到 `refs/backup/<分支名>`
  （不进 `refs/heads`：不污染分支列表、不触发 CI），幂等（远端 SHA 相同即跳过）；取回
  `git fetch origin 'refs/backup/*:refs/backup/*' && git branch <name> refs/backup/<name>`。
  `start` 审计会提示缺失数量。
- **残留目录回收**：`session-wt gc-dirs` 只清「`wt-*` + 未注册 + 无 `.git` + 够老」的目录
  （默认 dry-run）；有 `.git` 的一律不碰（可能是注册异常，先 `git worktree prune` 排查）。
- **独立审查惯例**：重要批次改动必须 3 个不同特长的独立 subagent 取证审查
  （自做 QA 不算数）。审查产出的 P0/P1 当场修复，P2/P3 登记在案。
- **记忆/文档治理**：AI 会话的持久记忆索引设硬限额（超限只加载部分=静默丢失知识）；
  文档口径变更须同步所有引用处。

---

## 平台替代映射（能满足约束就别自建）

| 自建件 | 平台现成等价物 | 替代条件 |
|---|---|---|
| 全局部署锁 | GitLab `resource_group` / GitHub Environments(单并发) | 部署动作进 CI |
| 红 CI 硬拦 | required status checks + protected branch | 走 PR 流程 |
| push-mine/rebase 推送 | PR + squash merge | 接受 PR 节奏 |
| 单调前进闸 | Merge Queue | 同上 |
| L1 worktree 工具 | ——（git 原生 worktree + 会话生态无此概念） | 无替代，自建 |
| 会话公告/收口 | ——（多 AI 会话特有） | 无替代，自建 |

## 三层复用模型（跨项目一致性规则）

复制到第二个项目起，问题就从「怎么建」变成「怎么不腐化」——各项目把通用脚本抄走
再各自魔改，三个月后就是七套行为不同的分叉，防护语义悄悄漂移。治理办法：所有工件
分三层，**通用层跨项目逐字节一致，参数层集中声明，定制层各建各的**。（定制层旧称「血肉层」，2026-10-13 更名对齐「基础↔定制」词汇；历史提交/记忆沿用旧称。）

**形态速览**（先知道每层用什么造）：七层里 5 层是脚本（L1/L3/L5 + L4 的门禁钩子）、
1 层纯约定（L2，git 原生命令）、1 层业务代码（L6 锁，必须与被串行进程同生命周期）；
**零数据库是有意设计**——所有状态落文件系统（锁=mkdir、版本标记=文件、公告=/tmp
文本、缓存=目录），换来零 schema/零迁移/零运维，且全 bash 部署链可直接操作一切。

| 复用层 | 含义 | 具体工件 | 治理规则 |
|---|---|---|---|
| **通用层** | 流程与防护语义 | session-wt.sh、push-mine.sh、deploy.sh 通用段（全局锁/CI 门禁/隔离部署/单调前进闸/公告/零中断流程骨架）、ci.yml 的 changes job 骨架、CLAUDE.md 约定模板 | **跨项目一致，禁止项目内魔改**：改动一律改在上游（模板源仓），各项目照 diff 同步升级；脚本头带 `sevenlocks-v<n>` 版本标记便于对齐 |
| **参数层** | 每项目一份显式配置 | 默认分支名、服务清单（名称/staging 路径/切换原语/健康端点/rsync 排除表占位）、worktree 接线清单（node_modules？.venv？）、runner 数量与 .env、公告与锁的文件路径 | **声明式集中**（脚本头配置块或独立 conf 文件），禁止把项目值硬编码进通用段逻辑里 |
| **定制层** | 项目固有资产 | deploy.sh 每服务段、ci.yml 执行 job、L6 锁挂载点、rsync 排除表实值、测试与评估套件、runbook 事故史 | **各建各的，禁止通用化**——它们编码的是项目自己的环境事实与质量资产 |

**归属判断一句话**：凡编码「环境事实」（服务器上有什么不在仓库里的文件、服务怎么
切换）或「质量资产」（测试/评估）的属于定制层；凡编码「流程与防护语义」（锁、门禁、
隔离、幂等重放）的属于通用层。

**一致性维护纪律**：
- 通用层脚本头部统一版本标记，跨项目 diff 一眼可查漂移；
- 上游修 bug / 补防线 → 各项目同步升级，不重新发明；
- 某项目「必须改通用层才能用」→ 先在参数层找空位；参数层放不下 → 说明它是定制，
  放进项目段——**永远不要为单项目改通用层**；
- 落地清单完成度对齐本文档 checklist；某层不建要显式声明原因（如「无评估套件 →
  L6 不建」），缺层不声明 = 防护面悄悄缩水。

## 移植必读的坑（全部实战踩过）

1. **bash 3.2（macOS 默认）**：`local a=1 b=$a` 同行声明——b 在赋值前展开，报 unbound；
   拆成两行。`$var` 后紧跟全角标点（中文注释/文案里高发）会把多字节字符粘进变量名——
   中文语境一律 `${var}`。
2. **BSD `mv -n` 拦不住「目录并入已存在目录」**：exit 0 且源被移入目标内部——
   发布落位用「check + plain mv + 残骸清理」，别信 -n。
3. **macOS 无 `flock` 命令**：互斥用 mkdir 原子性（见 L5）。
4. **workflow 级 paths 过滤会吞掉 run**：部署门禁查无 run 被自己拦死——过滤必须在 job 级。
5. **concurrency 淘汰 ≠ 失败**：pending run 被新 push 顶掉是设计行为，门禁要对 cancelled
   给出「可能从未执行」的指引，别当红灯拦部署。
6. **写回校验与 pid 锚定缺一不可**：mkdir 成功 ≠ 仍持有（清理竞态）；只看单 pid 会在
   隔离部署多层进程下误判过期。
7. **自建缓存的键**必须含 manifest+lockfile+工具链版本；`cp` 克隆失败回退前先清场
   （部分成功的目录会让回退拷贝嵌套）。
8. **launchd/systemd runner 无 shell profile**：PATH 注入靠 runner `.env`；多实例
   .env 漂移 = 随机红绿。
9. **runner 永不与生产同机**（原仓 OOM 全站假死实录；本机 48G 也好——资源隔离是原则问题）。
10. **共享暂存区是事故之源**：`git add -A` 在多会话工作区等于「提交别人的半成品」，
    pathspec 是纪律。
11. **stash 是代保管不是代决策**：收口时保全所有在制品（stash+backup 分支+快照），
    归还决策留给主人。
12. **评估与部署共享进程时**，不做串行+版本标注的评估结论不可信。
13. **gitignore 行内注释 = 否定模式整体失效**（首个外部项目落地实证，2026-10-14）：
    `!路径   # 注释` 在 git 里不是「模式+注释」——注释随空格粘进模式，整条匹配不到任何
    东西。命中形态：新 workflow 文件被 `*.yml` 全局规则静默吞掉、不出现在 untracked
    列表 → 部署门禁永远「无 CI run」fail-closed，且表象像 CI 坏了。检测：
    `git check-ignore -v <路径>` 看实际命中哪条；注释一律独立成行。
14. **gitignore 尾斜杠目录模式不匹配软链**：`.venv/` 只盖目录形态；session-wt 接线建
    的 `.venv` 是软链，以 `?? .venv` 出现在 status → dirty 误判、clean 误拒。接线产物
    一律在参数层 `SL_DIRTY_IGNORE` 显式排除（这正是该参数存在的原因），正则
    `^\?\? <路径>/?$` 兼容软链与目录双形态。
15. **溶解式落地（项目已有 deploy.sh，外部项目首例）**：旧脚本整体迁为服务段、新
    deploy.sh = 通用段包装层（外部用法接口不变）。三个必查点：① 迁移前
    `grep -rn "deploy.sh" tests/ scripts/` 找**程序性读取旧脚本源码文本**的测试
    （正则提段/顺序断言类）随迁改指，否则新 CI 首跑即红；② 原脚本只读模式
    （--status/--logs）在闸门前直通分流——只读查询取锁过闸门是体验灾难；直通与
    deploy_services 两处调用都带包装层标记，服务段入口对裸直调撞墙（防绕闸静默
    跑通），排障留显式逃生舱变量；③ `git mv` 后在原路径写新包装层 → rename 相似度
    检测断链，服务段历史不带 `--follow`（知情即可）。
16. **单调闸版本戳格式不匹配 = 静默 no-op**：隔离段「服务器当前版本读取」是定制点
    （示例为 `commit=<全sha>` 格式）；与项目实际版本戳格式（如裸短 sha）不符时 sed
    解析为空——区间摘要/回滚保护静默失效，只剩一行「读取失败」警告。**区间摘要为空
    必须当作闸门未激活**：适配后要真跑一次看到「当前 X → 新增 N 提交」区间才算关。
17. **验证方法论（外部落地总结）**：① 新装 CI 只收本地已验绿的测试——存量红灯会
    污染首跑（豁免走项目守护自带机制，勿改扫描器）；② CI 执行内容用干净环境彩排——
    conftest stub 撑不住真导入链，测试还可能硬编码 `.venv/bin/python` 起子进程；
    ③ 验证全程在 deploy_services 之前截停（人工确认步答 N / 被闸门拦截），零生产
    变更做完清单；代价是包装层→服务段全链要等首次真部署才 E2E——**首次真部署必须
    有人值守**。
18. **CI 门禁按 head_sha 查 run 不区分 workflow**：同 sha 上其他 workflow（如周扫
    安全扫描）的失败会被当作红 CI（有人值守仅警告、无人值守硬拦）。方向保守可接受；
    要精确化须改通用段按 workflow 过滤——属上游改动，勿在项目副本魔改。
19. **多 gh 账号本机：API 身份 ≠ git 推送身份**（v1.3 提交时实证）：gh 命令走活跃账号
    （`gh repo view` 显示 ADMIN、克隆可成功），git over https 却用 keychain 里另一账号
    的凭据——权限不匹配时 GitHub 掩码成 `Repository not found`，表象极像仓库不存在。
    一次性修法（不污染 keychain）：`GH_TOKEN=$(gh auth token) git -c credential.helper=
    -c credential.helper='!gh auth git-credential' push …`；⚠️ `-c credential.helper=X`
    是**追加**不是替换——不先空串重置列表，keychain 旧凭据先应答，新 helper 根本不被
    问到（第二次 404 的根因）。

20. **`git status --porcelain` 把未跟踪目录折叠成单条目**（收口保全实证）：
    默认输出对整个未跟踪目录只给一行 `?? dir/`——按行喂 tar/恢复清单会漏掉目录内容
    （曾 107 条目实含 219 文件，第一版 tar 只装 92）。保全/恢复一律
    `git status --porcelain -z --untracked-files=all`（-z 顺带解决含引号/中文路径的
    转义形态），恢复时现场重取清单而非复用旧文件。
21. **`git cherry` patch-id 判「已吸收」有同内容异 SHA 盲区**：squash/rebase 重放后
    patch-id 变化 → 恒 `+`，但内容可能已在远端（实战：Phase2 本地 deb4eff4 与 origin
    6d95b385 同秒同主题、补丁仅行号差=同内容可弃；而按记忆 SHA「7895474d」对号被三路
    审查证伪——那是无关提交）。弃本地提交前必须**逐对 diff 裁定**（diff 两提交树/补丁），
    勿按记忆 SHA 对号；反向也成立——同秒同主题也可能是真分歧（本地 104+ vs origin 35+）。

22. **ssh heredoc 内禁止引用本地 bash 函数**：`ssh host << 'DELIM' … DELIM` 的内容在
    远端 shell 执行——本地定义的函数（log_*/cleanup/release_*/deploy_history_line 等）
    在远端不存在，每次运行打印 `line N: xxx: command not found`；「让远端 trap 覆盖本地
    trap」在架构上不可能（独立进程）。bash -n / shellcheck 都发现不了（语法合法），
    必须语义守卫：遍历 ssh heredoc 区间比对本地函数定义集（实证脚本
    `scripts/check_deploy_heredoc_locals.py`，已进 CI；一次审查批误把 4 个本地函数
    链进 3 处远端 trap，每个 web 部署稳定 4 行噪音、声称的修复完全无效）。
    另注：trap 末命令失败**不改**退出码（bash 实测），所以这类错误只污染日志不改变结果——
    更难被发现，更该静态闸。

23. **审计只看得见 git 注册的 worktree**：`git worktree list` + `wt/` 分支回收对「手工复制
    到 /tmp 的目录（无 `.git`）」完全盲视——2026-10-22 实测 17 个/115MB 长期堆积，`worktree
    prune` 与分支 prune 都报「无可清理」。清理工具必须自带目录扫描（`gc-dirs`），且判据要
    fail-closed：未注册 + 无 `.git` + 够老三者同时成立才允许删。

24. **验证脚本的「参数替换」必须断言命中**：模板回归靠字符串替换把参数层改写成测试值；
    源码行一变（如 `SL_COPY_FILES` 多一个元素），`str.replace` 静默 no-op——verify 仍全绿，
    但测的已不是目标配置（实测两处失效数月无人知）。每处替换缺一即失败，让模板与
    verify 的漂移在第一秒暴露。

25. **安装钩子不能覆盖本机既有钩子**：`core.hooksPath` 常已指向 `.git/hooks`（本机有挡
    macOS 元数据文件的 pre-commit、Qoder 的 post-commit）。直接把新钩子复制成同名文件会静默
    顶掉现役守卫。安装器必须先识别「非本仓管理」的钩子、保留为 `<hook>.local`，由新钩子
    链式调用；模板回归要覆盖这条（链式钩子能拒绝提交才算保留成功）。

## 体系哲学（三条原则）

1. **结构消灭失误**：凡是「靠每个会话记住规矩」的防线都会腐化——能进工具的进工具，
   能进默认值的进默认值（部署默认走隔离树，逃生舱才需要显式变量）。
2. **并行最大化，串行点显式声明**：每个串行点（部署锁、评估锁、同 ref CI 队列）都是
   有意识的设计决策，配排队语义而非失败语义。
3. **逃生舱分层**：紧急情况必须能绕过一切（SKIP_* 变量），但危险组合（无人值守×跳过检查）
   必须叠加二次显式确认——摩擦力恰好挡住误用，不挡真急用。

## 落地清单（新项目复制顺序）

> 通用层工件从上游（模板源仓）**原样复制并保留版本标记**，参数层集中声明，定制层按骨架填空——归属规则见「三层复用模型」。
> 通用件在本仓（可复制模板包）中维护，新项目复制以本仓为准。

- [ ] AGENTS.md/CLAUDE.md 首条：编码一律 worktree 起步 + pathspec 提交（L1/L2 约定）
- [ ] `session-wt.sh`：start/list/push/clean + 接线 + hub 保鲜（L1）
- [ ] `push-mine.sh`：单提交幂等重放 + 拒 main（L3）
- [ ] `deploy.sh` 全局锁段：mkdir 原子 + 写回校验 + pid 锚定 + 排队语义（L5，最高优先）
- [ ] 部署树隔离 + 单调前进闸 + DEPLOY_REF fail-closed（L5）
- [ ] staging 预备 + 原子切换（venv 蓝绿 / 同分区 mv / rename 交换）+ 切换后健康检查与回滚（L5 零中断）
- [ ] CI：job 级 paths 过滤 + concurrency cancel:false + skipped=success 语义确认（L4）
- [ ] 部署门禁分级表 + SKIP×ASSUME 二次确认（L4/L5）
- [ ] 会话公告机制（`/tmp/<project>-session-notice.txt` + until 自过期 + 双入口打印）（L7）
- [ ] 保全式收口 runbook（backup/stash/快照/窗口条件）（L7）
- [ ] （有评估）串行锁 + 版本快照标注（L6）
- [ ] （self-hosted + 大依赖）本地克隆缓存 + runner 池 .env 同步规约（L4）
- [ ] 独立审查惯例 + 记忆索引限额（L7）

——SevenLocks v1.3（2026-10-14）：坑清单收录首个外部项目落地实证 +6 条（13~18：
gitignore 行内注释/尾斜杠软链/溶解式路径三必查/版本戳静默 no-op/验证方法论/head_sha 跨
workflow）；脚本零改动，版本标记不变。
v1.1（2026-10-12）：v1 定型七层；v1.1 增三层复用模型（通用/参数/定制 + 跨项目一致性纪律）。原仓实战数据：12 类提交层事故归零；部署并发从互踩
互滚到全局排队（生产实测 1 持有 + 1 排队）；部署切换全程用户无感（venv 蓝绿零中断 /
web 亚秒 mv）；CI 全量 run 串行 12min → 并行 5min；
web 依赖安装 5min → 克隆 7s；七层审查全部绿。
