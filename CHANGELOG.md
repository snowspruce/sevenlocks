# 版本

按版本倒序。

sevenlocks-v1.18.2（2026-11-09 下游项目实战回灌）：①`session-wt start` 的 hub 保鲜
从「落后大声告警」升级为**硬中止**（`SL_ALLOW_STALE_BASE=1` 显式放行）——下游项目实测
旧基线开工会让检索/改动画在过期代码上，演变成"本地 28 / 远端 110"分叉；FF 成功路径
（含 verify T10 保鲜测试）不受影响。②`hooks/pre-commit` 的逃生舱同样加落后检查
（`SL_ALLOW_HUB_COMMIT=1` 提交前仍查 `HEAD..origin/<branch>`，带
`SL_ALLOW_STALE_HUB=1` 二次放行）——事故背景：hub 落后 110 提交时连续在 hub 提交，
修复全进不了远端。③`verify-install.sh` 接线源支持溶解式回退：无
`scripts/claude-settings.json` 时取 `$SRC/../.claude/settings.json`（原按模板形态硬 cp，
溶解式项目必 FileNotFoundError，「L1 agent-guard 接线」假红）。④verify 的 deploy 接线源
同样二选一：无 `scripts/deploy-skeleton.sh` 时取 `$SRC/deploy.sh`（溶解式项目文件已改名，
原硬 cp 落空 → set_line 报 FileNotFoundError → 全套 FAIL）。

sevenlocks-v1.18.1（2026-10-26）：修两个「新项目一改参数层就误报」的校验缺陷——
① `verify-install.sh` 的参数化从「按默认值字面量替换」改为**按键重写**：项目把
`SL_DEV_BRANCH` / `SL_MIRROR_BRANCH` / 公告与历史路径改成自己的值后，不再报
「参数化失败：找不到 'SL_DEV_BRANCH="kewang"'」；镜像分支在 `session-wt` 与
`push-mine` 两处同步重写（否则 T12 假失败）。② `test_conflicts.sh` 自动读被测脚本的
`SL_DEV_BRANCH`/`SL_MIRROR_BRANCH`，并把 `SL_WT_ROOT` 改写到测试临时目录（不再依赖
参数层保留 `${SL_WT_ROOT:-…}` 的覆盖写法）。用「dev/prod + /srv 固定路径」的模拟项目
实测：verify 31 / conflicts 9 / guard 54 全绿。

sevenlocks-v1.18（2026-10-24 借力 Claude Code 并行机制）：①编辑时拦截
`agent-guard.py` + `claude-settings.json`——hub 编辑/hub 提交/`--no-verify`/
`commit`/`push` 的 `--no-verify`/`SKIP_PREPUSH_CHECK=1`/外部 `DEPLOY_IN_WORKTREE=1`/hub 整树覆盖 git（含 `checkout -f`/`switch -f`）在**工具调用前**被拒
（判据 git-dir==common-dir，realpath 防软链；解析 cd/-C/--git-dir/env 前缀/heredoc；
fail-open）；只对 Claude Code 生效，是增强层不是替代。②`session-wt conflicts <name>` 跨会话
冲突雷达：我的未提交 + 未推送提交 × 其他 worktree（含 hub）的改动集求交集 + origin 同文件
rebase 预警；只读。③verify 增 T21/T22 + 接线断言（31 PASS）、CI 增两套行为回归 + 钩子接线静态检查；
④补「升级到新版（已装项目）」章节与项目侧设置清单（模板仓按版本打 tag，支持三方合并）；
⑤修 adopt 自 v1.16 起的既有 P1——EXIT trap 引用 `local patch`，函数返回后 unbound，成功
也返回 1（调用方会把「已复制」当失败；verify T17 增退出码断言）。

sevenlocks-v1.17（2026-10-23 三路审查收口）：①`adopt` 修复 P0——目录内未跟踪文件逐文件枚举（原 `-- <dir>` 静默漏拷新文件）、目标 worktree 归属校验（跨仓/同名会话拒绝）、重命名自动补旧路径、幂等合入、失败汇总、拒绝 `.`/`..`/pathspec magic；②`push` 对未提交改动拒绝（原「无领先提交」假成功），`start` 不再 `rm -rf` 非空目录；③`pre-merge-commit` 链式 `.local` 并提示 `git merge --abort`，pre-push 逃生舱仍回放 `.local` stdin；④watchdog 改 awk 单遍配对（10k 行 39s→线性）且判活排除 `-c` 内联；⑤模板回灌哨兵 `-lc` 加固、hub 落后大声告警、watchdog 默认历史路径；⑥verify 补 6 项防假绿→27 PASS。

sevenlocks-v1.16（2026-10-23）：新增 `session-wt adopt <name> -- <path>…`——多会话共用主 checkout 时，把「属于本会话的 paths」的改动（已跟踪 diff + 未跟踪文件）**复制**进 worktree，主 checkout 一个字节不删；解决「主 checkout 混着他人在制品 + 提交守卫又禁止在主 checkout 提交」导致会话每次停下问人。`deploy.sh` 隔离日志明确「本地未提交改动不参与本次部署」；AGENTS 增「现场混着别人的改动」处置规约；verify T17（21 PASS）。

sevenlocks-v1.15（2026-10-22 三路审查收口）：修 2 个 P0 + 9 个 P1——①watchdog 以 100644 提交导致两处 `[ -x ]` 集成点全部失效（verify 的 chmod 掩盖）→ 模式修正 + CI 可执行位闸；②安装器 `$bak（` 全角粘连在 bash 3.2 下 unbound 中断（先移走现役钩子、新钩子未装 = 守卫裸奔）→ `${bak}` + 全源文件预检；③模板缺 `hooks/pre-push` 而安装器强制三件齐全 → 补齐 + verify 断言安装器 rc；④pre-push 链式调用吞 stdin（git-lfs 类 .local 拿到 EOF）→ 缓存回放；⑤`git merge --no-ff` 绕过 pre-commit → 新增 pre-merge-commit；⑥hub 迁移提示的全量 `git stash -u` 会摘走他人在制品 → 改 pathspec 导出；⑦`core.hooksPath` 跨仓共享时默认拒绝安装；⑧watchdog 顺序配对在交错历史下误报 → 按 pid 配对 + 存活超 2h 报「可能挂起」+ 排除祖先 pid；⑨gc-dirs 的注册判据因 `/tmp`→`/private/tmp` 恒不命中 + `stat -f` 在 GNU 崩 + 检查与删除间 TOCTOU → 物理路径归一/跨平台 mtime/GNU 优先/删前复核；⑩replicate 对已分叉远端 ref 永久失败且审计只比 ref 存在 → 镜像语义 force + 审计比 SHA；⑪`--history` 缺参死循环 → 参数校验。verify 新增「不误报」「源可执行位」「带 .git 目录保留」断言（20 PASS）。

sevenlocks-v1.14（2026-10-22 根治批）：把「卫生」从可观测推进到强制/自动——①`hooks/pre-commit` 主 checkout 提交硬拦（git-dir==git-common-dir 判定；链接 worktree 放行；`SL_ALLOW_HUB_COMMIT` 逃生舱；安装器保留本机钩子为 `.local` 链式）；②`session-wt gc-dirs` 回收无 `.git` 的 /tmp 残留（审计原先只看得见注册 worktree）；③`session-wt replicate` 备份分支推 `refs/backup/*`（抗机器丢失，幂等）；④`deploy_watchdog.sh` 把 START 无 END 报给下一次部署/start（SIGKILL 无法 trap，外部检查是唯一出路）；⑤verify 参数替换改为**缺一即失败**（原两处静默 no-op）+ 新增 T13-T16（19 PASS）。

sevenlocks-v1.13（2026-10-22）：`session-wt start` 顺带**本地镜像分支保鲜**——origin/<镜像> 由推送工具自动跟随，但本地 main 没人更新会停在旧提交（上游项目曾停 9-08 一个半月）；四条同时满足才快进（存在/未检出/是 origin 祖先/确实落后），失败静默跳过；verify 增 T12（12 PASS）。

sevenlocks-v1.12（2026-10-22 审查收口）：prune 修复——①删除失败不再误报成功（成功/失败分别计数，失败单列并返回非 0）②worktree 占用改用一次 `worktree list --porcelain` 解析（覆盖路径含空格/locked/目录已删，且去掉 O(B×W) 进程开销）③保留正则加边界 `^(kewang|main)$|^(backup|archive)(/|\$)`（原 `^main` 会过度保护 maintenance-*）④非法 SL_PRUNE_AGE_DAYS/正则改为 fail-closed 报错⑤审计与 prune 抽公共候选函数（消除两处极性漂移）；verify T11 加强（dry-run 不删/未吸收保留/边界用例）。

sevenlocks-v1.9（2026-10-19）：verify 增 `--drill`（单调闸自动验：取服务器当前版本父提交、跑必拦部署、断言版本戳未变=零部署）+ `DEPLOY_GATE_ONLY` 安全原语（闸门链走完即停、绝不触达服务）+ 末尾打印「验收必做」块（红 CI 硬拦的一次性配方与预期输出）。
sevenlocks-v1.8（2026-10-18）：新增 scripts/verify-install.sh + 模板仓 CI——安装自检/模板回归（首跑即抓出骨架 pipefail+set -e 吞 ssh 失败的真 bug）。
sevenlocks-v1.7（2026-10-18）：验证清单补「内层哨兵」「部署历史留痕」两条（此前清单落后于 v1.6 代码，两个刚上的防线等于没验）。
sevenlocks-v1.6（2026-10-18）：骨架补内层哨兵校验（DEPLOY_IN_WORKTREE 外部预设防旁门）+ L5 补「内层标记须可验证来源」与「默认路径覆盖面不得弱于逃生舱」两条机制。
sevenlocks-v1.5（2026-10-17）：坑 22=ssh heredoc 内禁止引用本地 bash 函数（语义守卫脚本 + 已进 CI；trap 末命令失败不改退出码故只污染日志更难发现）。
sevenlocks-v1.4（2026-10-17）：L7 收口保全四件套（补 untracked tar+持久位置+恢复目标=origin+挂起重验）+ 坑 20/21（porcelain 目录折叠 / cherry patch-id 同内容异 SHA 盲区）——源自上游项目 hub 混合现场收口实战。
sevenlocks-v1.3（2026-10-14）：收录首个外部项目落地实证——SEVEN_LOCKS 坑清单
+7 条（13~19：gitignore 行内注释/尾斜杠软链/溶解式路径三必查/版本戳静默 no-op/验证方法
论/head_sha 跨 workflow/多 gh 账号 API≠推送身份）、README 增溶解式放置说明与验证清单
两处硬停条件；脚本零改动。
sevenlocks-v1.2（2026-10-13）：v1.1 全量 + 参数层增 SL_GH_ACCOUNT（跨账号 gh 门禁）；v1.1（2026-10-12）：导出自上游项目（session-wt 含孤儿回收与镜像同步；deploy
含排队锁/门禁分级/隔离树/单调闸全量语义；CI 含 changes job 骨架）。
