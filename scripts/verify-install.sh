#!/bin/bash
# sevenlocks-v1.18 · verify-install.sh —— 安装自检 / 模板回归
#
# 做什么：在一个临时裸仓里真实驱动交付的脚本（session-wt / push-mine / deploy 骨架），
# 逐项验证「通用层机制」，输出 PASS / FAIL / SKIP（SKIP=需真实 CI 或服务器，无法本地自证）。
#
# 边界（务必理解）：本脚本只证**通用层机制在**，不证项目集成——
#   不覆盖：你的服务部署段（staging/原子切换/健康检查）、真实 CI job、服务器连通与版本戳格式、
#   评估层。那些必须按 README 的验证清单人工验，尤其「区间摘要为空=版本戳未适配」。
#
# 跑法：在模板仓根目录 `bash scripts/verify-install.sh`（也可在安装后的模板克隆里跑）。
# 退出码：0=无 FAIL（含 SKIP）；1=有 FAIL。
#
# 移植注：脚本会临时改写参数（分支名/锁/公告/历史路径），全部在 mktemp 目录内，不碰当前仓库。

set -uo pipefail

# 定位随附脚本：兼容两种布局——模板仓（脚本在 scripts/ 下，同级可找 session-wt.sh）
# 与其他镜像（扁平布局，脚本与 verify-install.sh 同目录）
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SELF_DIR/session-wt.sh" ]; then
    SRC="$SELF_DIR"
elif [ -f "$SELF_DIR/../scripts/session-wt.sh" ]; then
    SRC="$(cd "$SELF_DIR/../scripts" && pwd)"
else
    echo "ERROR: 找不到随附脚本（session-wt.sh/push-mine.sh/deploy-skeleton.sh 应与本脚本同目录或在其 ../scripts）"; exit 1
fi

DRILL=0
for _a in "$@"; do
    case "$_a" in
        --drill) DRILL=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      ↳ $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1（$2）"; SKIP=$((SKIP + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sevenlocks-verify.XXXXXX")
cleanup() { [ "${VERIFY_KEEP:-0}" = "1" ] && { echo "（VERIFY_KEEP=1：临时目录保留在 ${TMP}）"; return 0; }; rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "── SevenLocks 安装自检（临时仓：${TMP}）──"

# ── 准备：裸远端 + 工作克隆 + 参数化脚本 ─────────────────────────────
git init --bare -q "$TMP/origin.git" || { echo "ERROR: git init 失败"; exit 1; }
git clone -q "$TMP/origin.git" "$TMP/hub" || { echo "ERROR: git clone 失败"; exit 1; }
cd "$TMP/hub" || exit 1
git config user.email verify@sevenlocks.local
git config user.name verify
mkdir -p scripts scripts/hooks
cp "$SRC/session-wt.sh" scripts/session-wt.sh
cp "$SRC/push-mine.sh" scripts/push-mine.sh
cp "$SRC/deploy-skeleton.sh" scripts/deploy.sh
cp "$SRC/deploy_watchdog.sh" scripts/deploy_watchdog.sh
cp "$SRC/install-git-hooks.sh" scripts/install-git-hooks.sh
cp "$SRC/agent-guard.py" scripts/agent-guard.py
mkdir -p .claude
cp "$SRC/claude-settings.json" .claude/settings.json
cp "$SRC/hooks/"* scripts/hooks/
# 源文件可执行位检查（2026-10-22 审查 P1：watchdog 以 100644 提交，两处 [ -x ] 集成点
# 全部失效，而被下面的 chmod 掩盖——必须查源头）
for _f in "$SRC/deploy_watchdog.sh" "$SRC/install-git-hooks.sh" "$SRC/agent-guard.py" "$SRC"/hooks/*; do
    if [ ! -x "$_f" ]; then
        fail "源文件可执行位" "$_f 不可执行（应为 100755；chmod +x 后提交）"
    fi
done
chmod +x scripts/*.sh scripts/hooks/*

# 参数化（python 保证跨平台；只改参数层行）
# ⚠️ 每个替换都必须命中：源码与 verify 漂移时旧版是静默 no-op（P3，2026-10-22 实证
# SL_COPY_FILES/SL_DIRTY_IGNORE 两处已失效却无人知），这里改为缺一即失败。
python3 - "$TMP" <<'PYEOF'
import sys
tmp = sys.argv[1]
def sub(path, pairs):
    s = open(path).read()
    for a, b in pairs:
        if a not in s:
            raise SystemExit("参数化失败：%s 中找不到 %r（模板与 verify 漂移）" % (path, a[:70]))
        s = s.replace(a, b)
    open(path, 'w').write(s)

sub('scripts/session-wt.sh', [
    ('SL_DEV_BRANCH="kewang"', 'SL_DEV_BRANCH="dev"'),
    ('SL_MIRROR_BRANCH="main"', 'SL_MIRROR_BRANCH="main"'),
    ('SL_NOTICE_FILE="/tmp/myproject-session-notice.txt"', 'SL_NOTICE_FILE="%s/notice.txt"' % tmp),
    ('SL_WT_ROOT="${SL_WT_ROOT:-/tmp}"', 'SL_WT_ROOT="%s"' % tmp),
    ('SL_WIRE_DIRS=("web/node_modules" "service/.venv")', 'SL_WIRE_DIRS=()'),
    ('SL_COPY_FILES=("web/.env.local" "service/.env.local")', 'SL_COPY_FILES=()'),
    (r"SL_DIRTY_IGNORE='^\?\? (web/)?node_modules(/|$)|^\?\? service/\.venv(/|$)|^\?\? web/\.env\.local$|^\?\? service/\.env\.local$'", "SL_DIRTY_IGNORE=''"),
    ('SL_PRUNE_AGE_DAYS=3', 'SL_PRUNE_AGE_DAYS=0'),
    ('SL_HISTORY_LOG="/tmp/myproject-deploy-history.log"', 'SL_HISTORY_LOG="%s/history.log"' % tmp),
    ('SL_BACKUP_CHECK_TTL=3600', 'SL_BACKUP_CHECK_TTL=0'),
    ('SL_BACKUP_CHECK_STAMP="${TMPDIR:-/tmp}/myproject-backup-check.stamp"', 'SL_BACKUP_CHECK_STAMP="%s/backup.stamp"' % tmp),
])
sub('scripts/push-mine.sh', [
    ('SL_DEV_BRANCH="kewang"', 'SL_DEV_BRANCH="dev"'),
])
sub('scripts/deploy.sh', [
    ('SL_DEV_BRANCH="kewang"', 'SL_DEV_BRANCH="dev"'),
    ('SL_REPO_SLUG="owner/repo"', 'SL_REPO_SLUG="verify/verify"'),
    ('SL_LOCK_DIR="/tmp/myproject-deploy.lock"', 'SL_LOCK_DIR="%s/deploy.lock"' % tmp),
    ('SL_HISTORY_LOG="/tmp/myproject-deploy-history.log"', 'SL_HISTORY_LOG="%s/history.log"' % tmp),
    ('SL_NOTICE_FILE="/tmp/myproject-session-notice.txt"', 'SL_NOTICE_FILE="%s/notice.txt"' % tmp),
    ('SL_SERVER="user@host"', 'SL_SERVER="verify@127.0.0.1"'),
    ('SL_SELF_RE="deploy-skeleton"', 'SL_SELF_RE="deploy.sh"'),
])
print("参数化完成（全部替换命中）")
PYEOF

# 初始提交 + dev 分支推到裸仓
echo "init" > README.md
git add README.md scripts .claude
git commit -qm "init"
git branch -M dev
git push -q origin dev 2>/dev/null || { echo "ERROR: 初始推送失败"; exit 1; }

# 假 ssh：仅把「无服务器」快速化（真实连通性本就不在自检范围）
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 255\n' > "$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
# ⚠️ 不 export 全局 PATH：--drill 需要真实 ssh 读服务器版本戳。假 ssh 只注入到下面那次
# 「无服务器」部署调用（前缀 PATH=）。

# ── 1. worktree 全链 + 镜像同步 ────────────────────────────────────
if ./scripts/session-wt.sh start s1 >"$TMP/t1-start.log" 2>&1 \
   && [ -f "$TMP/wt-s1/README.md" ]; then
    ( cd "$TMP/wt-s1" && echo "a" > a.txt && git add a.txt && git commit -qm "t1" ) >/dev/null 2>&1
    if ./scripts/session-wt.sh push s1 >"$TMP/t1-push.log" 2>&1; then
        dev_sha=$(git -C "$TMP/origin.git" rev-parse refs/heads/dev 2>/dev/null)
        mir_sha=$(git -C "$TMP/origin.git" rev-parse refs/heads/main 2>/dev/null)
        if [ -n "$dev_sha" ] && [ "$dev_sha" = "$mir_sha" ] && grep -q "镜像: main 已 FF 同步" "$TMP/t1-push.log"; then
            pass "L1 worktree 全链 + 镜像同步（start/commit/push/clean）"
        else
            fail "L1 镜像同步" "push 后 origin/dev 与 origin/main 不一致或缺少镜像行"
        fi
        if ./scripts/session-wt.sh clean s1 >/dev/null 2>&1 && [ ! -d "$TMP/wt-s1" ]; then
            :
        else
            fail "L1 clean" "clean 后 worktree 未删除"
        fi
    else
        fail "L1 push" "见 $TMP/t1-push.log"
    fi
else
    fail "L1 start" "见 $TMP/t1-start.log"
fi

# ── 2. clean 对脏 worktree 必须拒绝 ────────────────────────────────
./scripts/session-wt.sh start s2 >/dev/null 2>&1
( cd "$TMP/wt-s2" && echo "dirty" > dirty.txt )
if ./scripts/session-wt.sh clean s2 >"$TMP/t2.log" 2>&1; then
    fail "L1 clean 守卫" "脏 worktree 未被拒绝清理"
else
    grep -q "拒绝清理" "$TMP/t2.log" && pass "L1 clean 守卫（脏 worktree 拒绝并披露）" \
        || fail "L1 clean 守卫" "拒绝但缺少披露文本"
    ./scripts/session-wt.sh clean s2 --force >/dev/null 2>&1
fi

# ── 3. 孤儿回收（已吸收回收 / 未吸收只提醒）────────────────────────
git branch wt/orphan-absorbed origin/dev 2>/dev/null
rm -rf "$TMP/wt-orphan-absorbed"
./scripts/session-wt.sh start s3 >"$TMP/t3.log" 2>&1
orphan_unpushed=$(git commit-tree "origin/dev^{tree}" -p origin/dev -m "verify: unpushed")
git update-ref refs/heads/wt/orphan-unpushed "$orphan_unpushed"
./scripts/session-wt.sh start s4 >"$TMP/t4.log" 2>&1
if grep -q "回收: 孤儿分支 wt/orphan-absorbed" "$TMP/t3.log" \
   && grep -q "提醒: 孤儿分支 wt/orphan-unpushed" "$TMP/t4.log" \
   && git show-ref --verify --quiet refs/heads/wt/orphan-unpushed; then
    pass "L1 孤儿回收（已吸收回收 / 未吸收只提醒）"
else
    fail "L1 孤儿回收" "见 $TMP/t3.log $TMP/t4.log"
fi
./scripts/session-wt.sh clean s3 >/dev/null 2>&1
./scripts/session-wt.sh clean s4 >/dev/null 2>&1
git branch -D wt/orphan-unpushed >/dev/null 2>&1

# ── 4. 会话公告（打印 / 过期不打印）────────────────────────────────
printf 'until=20991231\nverify notice line\n' > "$TMP/notice.txt"
./scripts/session-wt.sh list >"$TMP/t5a.log" 2>&1
printf 'until=20200101\nexpired line\n' > "$TMP/notice.txt"
./scripts/session-wt.sh list >"$TMP/t5b.log" 2>&1
if grep -q "verify notice line" "$TMP/t5a.log" && ! grep -q "expired line" "$TMP/t5b.log"; then
    pass "L7 会话公告（未过期打印 / 过期自弃）"
else
    fail "L7 会话公告" "打印或过期行为不符"
fi
rm -f "$TMP/notice.txt"

# ── 5. push-mine 单提交重放 ───────────────────────────────────────
echo "b" > b.txt
git add b.txt && git commit -qm "push-mine verify"
if ./scripts/push-mine.sh HEAD >"$TMP/t6.log" 2>&1 && git -C "$TMP/origin.git" cat-file -e "$(git rev-parse HEAD):b.txt" 2>/dev/null; then
    pass "L3 push-mine（单提交幂等重放）"
else
    fail "L3 push-mine" "见 $TMP/t6.log"
fi

# ── 6. 内层哨兵：外部预设必须拒绝 ─────────────────────────────────
if DEPLOY_IN_WORKTREE=1 ./scripts/deploy.sh all >"$TMP/t7.log" 2>&1; then
    fail "L5 内层哨兵" "外部预设 DEPLOY_IN_WORKTREE=1 未被拒绝"
else
    grep -q "不是隔离部署树\|nonce 不匹配" "$TMP/t7.log" && pass "L5 内层哨兵（外部预设拒绝）" \
        || fail "L5 内层哨兵" "被拒但原因不符：$(head -2 "$TMP/t7.log")"
fi

# ── 7. 锁自愈 + 全链部署 + 历史留痕 ───────────────────────────────
mkdir -p "$TMP/deploy.lock"
printf '999999|all|1\n' > "$TMP/deploy.lock/info"   # 死 pid = 过期锁
if PATH="$TMP/bin:$PATH" SKIP_CI_CHECK=1 CI_SKIP_CONFIRMED=1 DEPLOY_ASSUME_YES=1 DEPLOY_ALLOW_ROLLBACK=1 \
   ./scripts/deploy.sh all >"$TMP/t8.log" 2>&1; then
    if grep -q "发现过期部署锁" "$TMP/t8.log"; then
        pass "L5 锁自愈（死 pid 过期锁自动清理）"
    else
        fail "L5 锁自愈" "未清理过期锁"
    fi
    if grep -q "START" "$TMP/history.log" 2>/dev/null && grep -q "END" "$TMP/history.log" 2>/dev/null; then
        pass "L5 部署历史留痕（START/END 配对）"
    else
        fail "L5 部署历史留痕" "history.log 缺 START/END：$(cat "$TMP/history.log" 2>/dev/null | head -3)"
    fi
    if grep -q "内层哨兵 nonce 不匹配\|不是隔离部署树" "$TMP/t8.log"; then
        fail "L5 隔离全链" "合法隔离内层被哨兵误拦"
    else
        pass "L5 隔离全链（外层→哨兵→内层→服务插槽）"
    fi
else
    fail "L5 部署全链" "退出非 0：$(tail -3 "$TMP/t8.log")"
    fail "L5 锁自愈" "部署未跑通，无法判定"
    fail "L5 部署历史留痕" "部署未跑通，无法判定"
fi

# ── 8. 闸门试跑原语：DEPLOY_GATE_ONLY 必须停住、不得触达服务 ─────────
if PATH="$TMP/bin:$PATH" SKIP_CI_CHECK=1 CI_SKIP_CONFIRMED=1 DEPLOY_ASSUME_YES=1 DEPLOY_ALLOW_ROLLBACK=1 \
   DEPLOY_GATE_ONLY=1 ./scripts/deploy.sh all >"$TMP/t9.log" 2>&1; then
    if grep -q "闸门链已走完" "$TMP/t9.log" && ! grep -q "骨架未实现服务段" "$TMP/t9.log"; then
        pass "L5 闸门试跑原语（DEPLOY_GATE_ONLY 停住且未触达服务）"
    else
        fail "L5 闸门试跑原语" "输出不符：$(tail -3 "$TMP/t9.log")"
    fi
else
    fail "L5 闸门试跑原语" "退出非 0：$(tail -3 "$TMP/t9.log")"
fi

# ── 9. prune：dry-run 不删 / --yes 只删已吸收 / 保护项与未吸收保留 ────
git branch prune-me origin/dev >/dev/null 2>&1
git branch maintenance-x origin/dev >/dev/null 2>&1     # 边界：旧正则 ^main 会过度保护
git branch backup/keep-me origin/dev >/dev/null 2>&1
_unabs=$(git commit-tree "origin/dev^{tree}" -p origin/dev -m "verify: unpushed")
git branch unabsorbed-me "$_unabs" >/dev/null 2>&1
./scripts/session-wt.sh prune >"$TMP/t11a.log" 2>&1
_dry_kept=0
git show-ref --verify --quiet refs/heads/prune-me && _dry_kept=1
./scripts/session-wt.sh prune --yes >"$TMP/t11b.log" 2>&1
if grep -q "prune-me" "$TMP/t11a.log" && [ "$_dry_kept" = "1" ] \
   && ! git show-ref --verify --quiet refs/heads/prune-me \
   && ! git show-ref --verify --quiet refs/heads/maintenance-x \
   && git show-ref --verify --quiet refs/heads/backup/keep-me \
   && git show-ref --verify --quiet refs/heads/unabsorbed-me; then
    pass "L1 prune（dry-run 不删 / 已吸收删除 / 保护与未吸收保留）"
else
    fail "L1 prune" "dry_kept=${_dry_kept} 列表：$(tail -3 "$TMP/t11a.log")"
fi
git branch -D unabsorbed-me >/dev/null 2>&1 || true

# ── 10. 本地镜像分支保鲜：落后时 start 自动快进 ────────────────────
_main_old=$(git rev-parse HEAD~1)              # 落后一个提交才能触发快进
git branch main "$_main_old" >/dev/null 2>&1
./scripts/session-wt.sh start s6 >"$TMP/t12.log" 2>&1
_main_now=$(git rev-parse main 2>/dev/null)
_origin_main=$(git rev-parse origin/main 2>/dev/null)
if grep -q "已快进到 origin/main" "$TMP/t12.log" && [ "$_main_now" = "$_origin_main" ]; then
    pass "L1 本地 main 保鲜（落后时 start 自动快进）"
else
    fail "L1 本地 main 保鲜" "未快进或未提示：$(grep -a 'main' "$TMP/t12.log" | head -3)"
fi
./scripts/session-wt.sh clean s6 >/dev/null 2>&1

# ── 13. hub 提交守卫：主 checkout 拒绝 / 链接 worktree 放行 / 逃生舱 / 链式保留 ──
if ! ./scripts/install-git-hooks.sh >"$TMP/t13a.log" 2>&1; then
    fail "L1 hub 提交守卫" "安装器失败（rc≠0）：$(tail -2 "$TMP/t13a.log")"
fi
if git commit --allow-empty -m "hub must fail" >"$TMP/t13b.log" 2>&1; then
    fail "L1 hub 提交守卫" "主 checkout 提交未被拒绝"
else
    grep -q "拒绝提交：主 checkout" "$TMP/t13b.log" && pass "L1 hub 提交守卫（主 checkout 拒绝）" \
        || fail "L1 hub 提交守卫" "被拒但提示不对：$(tail -3 "$TMP/t13b.log")"
fi
_head_before=$(git rev-parse HEAD)
if SL_ALLOW_HUB_COMMIT=1 git commit --allow-empty -m "hub override" >"$TMP/t13c.log" 2>&1; then
    pass "L1 hub 提交守卫（逃生舱放行）"
else
    fail "L1 hub 提交守卫" "逃生舱失效：$(tail -3 "$TMP/t13c.log")"
fi
git reset --hard --quiet "$_head_before"
./scripts/session-wt.sh start s7 >"$TMP/t13d.log" 2>&1
if ( cd "$TMP/wt-s7" && git commit --allow-empty -m "wt ok" ) >"$TMP/t13e.log" 2>&1; then
    pass "L1 hub 提交守卫（链接 worktree 放行）"
else
    fail "L1 hub 提交守卫" "链接 worktree 被误拦：$(tail -3 "$TMP/t13e.log")"
fi
# 本机既有同名钩子必须被保留并链式调用（不能被静默顶掉）
printf '#!/bin/sh\necho LOCAL-HOOK-RAN >&2\nexit 7\n' > "$(git rev-parse --git-path hooks)/pre-commit.local"
chmod +x "$(git rev-parse --git-path hooks)/pre-commit.local"
if ( cd "$TMP/wt-s7" && git commit --allow-empty -m "chain" ) >"$TMP/t13f.log" 2>&1; then
    fail "L1 hub 提交守卫" "链式本机钩子未生效"
else
    grep -q "LOCAL-HOOK-RAN" "$TMP/t13f.log" && pass "L1 hub 提交守卫（本机既有钩子链式保留）" \
        || fail "L1 hub 提交守卫" "本机钩子未被调用：$(tail -3 "$TMP/t13f.log")"
fi
rm -f "$(git rev-parse --git-path hooks)/pre-commit.local"
./scripts/session-wt.sh clean s7 --force >/dev/null 2>&1

# ── 14. gc-dirs：非 worktree 残留（无 .git）dry-run 不删 / --yes 删 / 注册树不动 ──
mkdir -p "$TMP/wt-scratch" && echo junk > "$TMP/wt-scratch/junk.txt"
mkdir -p "$TMP/wt-gitfile" && : > "$TMP/wt-gitfile/.git"   # 有 .git（哪怕是文件）= 非残留，必须保留
./scripts/session-wt.sh start s8 >/dev/null 2>&1
./scripts/session-wt.sh gc-dirs >"$TMP/t14a.log" 2>&1
_dry_kept=0; [ -d "$TMP/wt-scratch" ] && _dry_kept=1
./scripts/session-wt.sh gc-dirs --yes >"$TMP/t14b.log" 2>&1
if grep -q "wt-scratch" "$TMP/t14a.log" && [ "$_dry_kept" = "1" ] \
   && [ ! -d "$TMP/wt-scratch" ] && [ -d "$TMP/wt-s8" ] && [ -d "$TMP/wt-gitfile" ]; then
    pass "L1 gc-dirs（dry-run 不删 / --yes 删残留 / 注册树与带 .git 目录保留）"
else
    fail "L1 gc-dirs" "dry_kept=${_dry_kept} gitfile=$([ -d "$TMP/wt-gitfile" ] && echo kept || echo GONE)；$(tail -3 "$TMP/t14a.log")"
fi
rm -rf "$TMP/wt-gitfile"
./scripts/session-wt.sh clean s8 >/dev/null 2>&1

# ── 15. replicate：backup 分支推远端 refs/backup/*（抗机器丢失 + 幂等）──────
if ./scripts/session-wt.sh replicate >"$TMP/t15a.log" 2>&1; then
    _bsha=$(git rev-parse backup/keep-me)
    _rsha=$(git -C "$TMP/origin.git" rev-parse refs/backup/backup/keep-me 2>/dev/null || true)
    ./scripts/session-wt.sh replicate >"$TMP/t15b.log" 2>&1
    if [ -n "$_rsha" ] && [ "$_bsha" = "$_rsha" ] && grep -q "已最新 1" "$TMP/t15b.log"; then
        pass "L7 备份副本（backup 分支推远端 + 幂等）"
    else
        fail "L7 备份副本" "远端 ref 缺失或第二轮非幂等：$(tail -2 "$TMP/t15b.log")"
    fi
else
    fail "L7 备份副本" "replicate 失败：$(tail -3 "$TMP/t15a.log")"
fi
# 远端 SHA 过期必须被 audit 发现（只比 ref 存在会漏报「有副本」）
_stale_sha=$(git commit-tree "HEAD^{tree}" -p HEAD -m "verify: stale backup probe")
git branch -f backup/keep-me "$_stale_sha" >/dev/null 2>&1
./scripts/session-wt.sh audit >"$TMP/t15c.log" 2>&1
if grep -q "远端已过期" "$TMP/t15c.log"; then
    pass "L7 备份审计（远端 SHA 过期可比出）"
else
    fail "L7 备份审计" "远端已过期未被发现：$(grep -a 'backup' "$TMP/t15c.log" | head -2)"
fi

# ── 16. 中断部署：正常配对不误报；孤儿 START 在下一次部署启动时报出（只报不拦）──
# 交错历史（START A / START B / END A / END B）：按 pid 配对必须全闭合；顺序配对会误报
_ots=$(date -v-2H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '-2 hours' '+%Y-%m-%d %H:%M:%S')
printf '%s|START|pid=900001|target=all lock=held\n%s|START|pid=900002|target=all lock=held\n%s|END|pid=900001|rc=0 dur=1s lock=held\n%s|END|pid=900002|rc=0 dur=1s lock=held\n' \
    "$_ots" "$_ots" "$_ots" "$_ots" > "$TMP/hist-interleaved.log"
if ./scripts/deploy_watchdog.sh --history "$TMP/hist-interleaved.log" --quiet >/dev/null 2>&1; then
    pass "L5 交错 pid 配对（不误报）"
else
    fail "L5 交错 pid 配对" "START A/B + END A/B 被误报为中断"
fi
./scripts/session-wt.sh audit >"$TMP/t16a.log" 2>&1
if grep -q "部署中断" "$TMP/t16a.log"; then
    fail "L5 中断部署不误报" "正常 START/END 配对被报成中断：$(grep -a '部署中断' "$TMP/t16a.log" | head -2)"
else
    pass "L5 中断部署不误报（按 pid 配对）"
fi
_old_ts=$(date -v-2H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '-2 hours' '+%Y-%m-%d %H:%M:%S')
printf '%s|START|pid=999999|target=all lock=held\n' "$_old_ts" >> "$TMP/history.log"
if PATH="$TMP/bin:$PATH" SKIP_CI_CHECK=1 CI_SKIP_CONFIRMED=1 DEPLOY_ASSUME_YES=1 DEPLOY_ALLOW_ROLLBACK=1 \
   DEPLOY_GATE_ONLY=1 ./scripts/deploy.sh all >"$TMP/t16.log" 2>&1; then
    if grep -q "上一次部署未正常结束" "$TMP/t16.log" && grep -q "pid=999999" "$TMP/t16.log"; then
        pass "L5 中断部署可见（孤儿 START 在下一次部署启动时报出）"
    else
        fail "L5 中断部署可见" "未报出孤儿 START：$(grep -a '部署' "$TMP/t16.log" | tail -2)"
    fi
else
    fail "L5 中断部署可见" "GATE_ONLY 退出非 0：$(tail -3 "$TMP/t16.log")"
fi

# ── 17. adopt：主 checkout 指定 paths 复制进 worktree，主 checkout 一个字节不删 ──
echo "adopt-mod" >> README.md
echo "untracked" > adopt-new.txt
_adopt_rc=0
./scripts/session-wt.sh adopt s9 -- README.md adopt-new.txt >"$TMP/t17.log" 2>&1 || _adopt_rc=$?
if [ "$_adopt_rc" != "0" ]; then
    # EXIT trap 引用 local 变量会 unbound → 成功也返回 1（2026-10-24 实测；调用方会当失败）
    fail "L1 adopt 退出码" "rc=${_adopt_rc}（应为 0）：$(tail -2 "$TMP/t17.log")"
elif grep -q "adopt-mod" "$TMP/wt-s9/README.md" 2>/dev/null \
   && [ -f "$TMP/wt-s9/adopt-new.txt" ] \
   && grep -q "adopt-mod" README.md && [ -f adopt-new.txt ]; then
    pass "L1 adopt（改动复制进 worktree / 主 checkout 不丢 / 退出码 0）"
else
    fail "L1 adopt" "$(tail -3 "$TMP/t17.log")"
fi
# push 对未提交改动必须拒绝（否则「无领先提交」假成功，部署仍是旧代码）
if ./scripts/session-wt.sh push s9 >"$TMP/t17b.log" 2>&1; then
    fail "L1 adopt/push 脏改动守卫" "未提交改动的 worktree 竟 push 成功"
else
    grep -q "未提交改动" "$TMP/t17b.log" && pass "L1 push 脏改动守卫（拒绝假成功）" \
        || fail "L1 push 脏改动守卫" "被拒但提示不对：$(tail -2 "$TMP/t17b.log")"
fi
./scripts/session-wt.sh clean s9 --force >/dev/null 2>&1
git checkout -- README.md 2>/dev/null || true
rm -f adopt-new.txt

# ── 18. adopt -- <dir>：已跟踪改动 + 目录内未跟踪文件必须一起搬（P0 回归）──
echo "tracked-mod" >> scripts/push-mine.sh
echo "brand-new" > scripts/adopt-dir-new.txt
./scripts/session-wt.sh adopt s10 -- scripts >"$TMP/t18.log" 2>&1
if grep -q "tracked-mod" "$TMP/wt-s10/scripts/push-mine.sh" 2>/dev/null \
   && [ -f "$TMP/wt-s10/scripts/adopt-dir-new.txt" ]; then
    pass "L1 adopt 目录（跟踪+未跟踪文件一起搬）"
else
    fail "L1 adopt 目录" "目录内未跟踪文件漏拷：$(tail -3 "$TMP/t18.log")"
fi
./scripts/session-wt.sh clean s10 --force >/dev/null 2>&1
git checkout -- scripts/push-mine.sh 2>/dev/null || true
rm -f scripts/adopt-dir-new.txt

# ── 19. adopt/push 拒绝非本仓库的 /tmp/wt-<name>（全局命名空间防护）──
git init -q "$TMP/otherrepo" && git -C "$TMP/otherrepo" -c user.email=v@v -c user.name=v commit -q --allow-empty -m other
git -C "$TMP/otherrepo" worktree add "$TMP/wt-foreign" --detach --quiet 2>/dev/null || true
echo "x" >> README.md
if ./scripts/session-wt.sh adopt foreign -- README.md >"$TMP/t19.log" 2>&1; then
    fail "L1 adopt 归属校验" "竟写入别的仓库的 worktree"
else
    grep -q "不是本仓库的 worktree" "$TMP/t19.log" && pass "L1 adopt 归属校验（拒绝跨仓写入）" \
        || fail "L1 adopt 归属校验" "被拒但原因不符：$(tail -2 "$TMP/t19.log")"
fi
git -C "$TMP/otherrepo" worktree remove --force "$TMP/wt-foreign" >/dev/null 2>&1 || true

# ── 20. adopt 拒绝路径穿越 / pathspec magic ──
if ./scripts/session-wt.sh adopt s12 -- foo/.. >"$TMP/t20.log" 2>&1; then
    fail "L1 adopt 路径校验" "foo/.. 未被拒绝"
else
    grep -q "含 \\.\\.\\|非法路径" "$TMP/t20.log" && pass "L1 adopt 路径校验（拒绝 .. / pathspec magic）" \
        || fail "L1 adopt 路径校验" "被拒但提示不对：$(tail -2 "$TMP/t20.log")"
fi
git checkout -- README.md 2>/dev/null || true

# ── 21. agent-guard：编辑时拦截（hub 拒绝 / worktree 放行 / 逃生舱 / fail-open）──
# 定位：Claude Code PreToolUse 增强层；git 钩子仍是跨 agent 底线。判据=git-dir==common-dir。
git worktree add -q "$TMP/wt-g" -b wt/g 2>/dev/null || true
_guard_rc() {  # $1=payload ${2:-env 赋值} → 打印退出码
    local rc=0
    if [ -n "${2:-}" ]; then
        printf '%s' "$1" | env $2 python3 scripts/agent-guard.py >/dev/null 2>"$TMP/t21.err" || rc=$?
    else
        printf '%s' "$1" | python3 scripts/agent-guard.py >/dev/null 2>"$TMP/t21.err" || rc=$?
    fi
    echo "$rc"
}
_p_edit() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$1" "$2"; }
_p_bash() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2"; }

_rc_hub=$(_guard_rc "$(_p_edit "$PWD/README.md" "$PWD")")
_rc_wt=$(_guard_rc "$(_p_edit "$TMP/wt-g/README.md" "$TMP/wt-g")")
_rc_c_hub=$(_guard_rc "$(_p_bash "git commit -m x" "$PWD")")
_rc_c_wt=$(_guard_rc "$(_p_bash "git commit -m x" "$TMP/wt-g")")
_rc_dep=$(_guard_rc "$(_p_bash "DEPLOY_IN_WORKTREE=1 ./scripts/deploy.sh" "$PWD")")
_rc_bad=$(_guard_rc 'not-json')
_rc_esc=$(_guard_rc "$(_p_edit "$PWD/README.md" "$PWD")" "SL_ALLOW_HUB_EDIT=1")
if [ ! -d "$TMP/wt-g" ]; then
    # 建树失败时「worktree 放行」会借 guard 的 fail-open 假绿（非仓库路径 → 放行）
    fail "L1 agent-guard" "worktree wt-g 建立失败——后续断言不可信"
elif [ "$_rc_hub" = "2" ] && [ "$_rc_wt" = "0" ] && [ "$_rc_c_hub" = "2" ] \
   && [ "$_rc_c_wt" = "0" ] && [ "$_rc_dep" = "2" ] && [ "$_rc_bad" = "0" ] && [ "$_rc_esc" = "0" ]; then
    pass "L1 agent-guard（hub 编辑/提交拒绝、worktree 放行、部署变量拒绝、逃生舱、坏输入 fail-open）"
else
    fail "L1 agent-guard" "rc: hub-edit=$_rc_hub wt-edit=$_rc_wt hub-commit=$_rc_c_hub wt-commit=$_rc_c_wt deploy=$_rc_dep badjson=$_rc_bad escape=$_rc_esc"
fi

# 接线（.claude/settings.json 里的真实命令）：能拦、且定位不到脚本时 fail-open（exit 0）
_hook_cmd=$(python3 -c "import json;print(json.load(open('.claude/settings.json'))['hooks']['PreToolUse'][0]['hooks'][0]['command'])")
_rc_hook_block=$(printf '%s' "$(_p_edit "$PWD/README.md" "$PWD")" | sh -c "$_hook_cmd" >/dev/null 2>&1; echo $?)
_rc_hook_missing=$(cd "$TMP" && printf '%s' "$(_p_bash "git commit -m x" "$TMP")" | sh -c "$_hook_cmd" >/dev/null 2>&1; echo $?)
if [ "$_rc_hook_block" = "2" ] && [ "$_rc_hook_missing" = "0" ]; then
    pass "L1 agent-guard 接线（settings.json 命令可拦；脚本缺失时 fail-open）"
else
    fail "L1 agent-guard 接线" "hook rc: block=$_rc_hook_block missing=$_rc_hook_missing"
fi

# ── 22. conflicts：跨会话冲突雷达（交集报出 / 无交集明确）──
git worktree add -q "$TMP/wt-h" -b wt/h 2>/dev/null || true
echo g >> "$TMP/wt-g/README.md"
echo h >> "$TMP/wt-h/README.md"
if [ -d "$TMP/wt-h" ] && ./scripts/session-wt.sh conflicts g >"$TMP/t22.log" 2>&1 \
   && grep -q "会话 h" "$TMP/t22.log" && grep -q "README.md" "$TMP/t22.log"; then
    pass "L1 conflicts（跨会话同文件交集报出）"
else
    fail "L1 conflicts" "$(tail -3 "$TMP/t22.log")"
fi
git -C "$TMP/wt-g" checkout -q -- README.md 2>/dev/null
echo only > "$TMP/wt-g/only-g.txt"
if ./scripts/session-wt.sh conflicts g >"$TMP/t22b.log" 2>&1 && grep -q "无跨会话文件重叠" "$TMP/t22b.log"; then
    pass "L1 conflicts（无交集时明确报无重叠）"
else
    fail "L1 conflicts 无交集" "$(tail -3 "$TMP/t22b.log")"
fi

# ── 需真实环境，无法本地自证 ──────────────────────────────────────
skip "L4 CI 路径过滤" "需真实 CI：按 README 验证清单第 9 条"
skip "L4 门禁分级（红 CI 硬拦）" "需造红 run：按 README 验证清单第 5 条"
if [ "$DRILL" = "1" ]; then
    # ── drill：单调前进闸（安全——DEPLOY_GATE_ONLY 保证绝不触达服务）────────────
    # 需要真实项目环境（本脚本自身只带模板骨架，无服务器配置），由调用方显式给出：
    #   VERIFY_DRILL_DEPLOY       项目 deploy.sh 路径（默认 ./scripts/deploy.sh）
    #   VERIFY_DRILL_SERVER       user@host
    #   VERIFY_DRILL_VERSION_FILE 服务 .deploy-version 的绝对路径（如 /opt/app/.deploy-version）
    #   VERIFY_DRILL_TARGET       部署目标参数（默认 all）
    if [ -z "${VERIFY_DRILL_SERVER:-}" ] || [ -z "${VERIFY_DRILL_VERSION_FILE:-}" ]; then
        skip "L5 单调前进闸 drill" "未提供 VERIFY_DRILL_SERVER / VERIFY_DRILL_VERSION_FILE（见脚本头注释）"
    else
        _dep="${VERIFY_DRILL_DEPLOY:-./scripts/deploy.sh}"
        _tgt="${VERIFY_DRILL_TARGET:-all}"
        if [ ! -f "$_dep" ]; then
            fail "L5 单调前进闸 drill" "找不到项目 deploy.sh：$_dep"
        else
            _ver=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$VERIFY_DRILL_SERVER" \
                "cat '${VERIFY_DRILL_VERSION_FILE}' 2>/dev/null | head -1" 2>/dev/null || true)
            _cur=$(printf '%s' "$_ver" | sed -n 's/.*commit=\([0-9a-f]*\).*/\1/p')
            if [ -z "$_cur" ]; then
                fail "L5 单调前进闸 drill" "读不到服务器版本戳（${VERIFY_DRILL_VERSION_FILE}）——先正常部署一次再 drill"
            else
                _prev=$(git rev-parse "${_cur}^" 2>/dev/null || true)
                if [ -z "$_prev" ]; then
                    fail "L5 单调前进闸 drill" "无法从 ${_cur} 取父提交（本地缺该对象？）"
                else
                    _out_marker=$(mktemp "${TMPDIR:-/tmp}/drill.XXXXXX")
                    DEPLOY_REF="$_prev" DEPLOY_ASSUME_YES=1 DEPLOY_GATE_ONLY=1 SKIP_GIT_CHECK=1 \
                        bash "$_dep" "$_tgt" >"$_out_marker" 2>&1
                    _rc=$?
                    _after=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$VERIFY_DRILL_SERVER" \
                        "cat '${VERIFY_DRILL_VERSION_FILE}' 2>/dev/null | head -1" 2>/dev/null || true)
                    if [ "$_rc" -ne 0 ] && grep -q "回滚风险" "$_out_marker" && [ "$_after" = "$_ver" ]; then
                        pass "L5 单调前进闸（旧提交被拦 + 版本戳未变=零部署）"
                    else
                        fail "L5 单调前进闸 drill" "rc=${_rc}；期望非 0 且含「回滚风险」且版本戳不变；输出尾部：$(tail -2 "$_out_marker")"
                    fi
                    rm -f "$_out_marker"
                fi
            fi
        fi
    fi
else
    skip "L5 单调前进闸" "需真实服务器版本戳：加 --drill 并给出 VERIFY_DRILL_SERVER/VERSION_FILE"
fi

cat <<'NEXT'

── 验收必做（无法本地自证，安装时人工执行一次并留存输出）────────────────
L4 门禁分级（红 CI 硬拦）——不自动造红，避免污染 CI：
  1) 探针分支造一个必红测试并推送：
       git checkout -b probe/red origin/<DEV>
       echo 'import test from "node:test"; test("probe", () => { throw new Error("probe red") });' > <测试目录>/probe-red.test.mjs
       git add <测试目录>/probe-red.test.mjs && git commit -m "probe: red" && git push origin probe/red
  2) 等该分支 run 结论为 failure（gh run list --branch probe/red --limit 1）
  3) 打门禁（闸在服务动作之前退出，零部署）：
       SKIP_GIT_CHECK=1 DEPLOY_REF=origin/probe/red DEPLOY_ASSUME_YES=1 ./scripts/deploy.sh <目标>
     期望：「❌ CI 结论为 failure，且为无人值守部署——拒绝带红 CI 上线」+ 非 0 退出
  4) 清理：git push origin --delete probe/red && git branch -D probe/red

L5 单调前进闸（可自动）：bash scripts/verify-install.sh --drill \
       VERIFY_DRILL_SERVER=<user@host> VERIFY_DRILL_VERSION_FILE=/opt/<svc>/.deploy-version
     期望：PASS（旧提交被拦 + 版本戳未变）
NEXT

echo "── 结果：PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP} ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
