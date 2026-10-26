#!/usr/bin/env bash
# session-wt conflicts 行为回归（2026-10-24）。
#
# 在临时裸仓 + 两个会话 worktree + hub 里真跑冲突雷达，验证：
#   1) 未提交 vs 未提交、未提交 vs 未推送提交、与 hub 在制品 三种交集都能报出
#   2) 无交集时明确说「无重叠」
#   3) origin 在分支点之后改过同一文件 → 报 rebase 可能冲突
#   4) 已提交的纯重命名：旧路径计入（--no-renames；100% 相似度才测得出）
#   5) 暂存区重命名（R 在 X 位）旧路径计入
#   6) 双方同名未跟踪文件也算交集
#   7) 有会话读不到改动集（无共同祖先）→ 明确「结论不完整」，不得报「无重叠」
#   8) 拒绝读取别的仓库的 /tmp/wt-<name>（归属校验）
#   9) 临时目录不残留（TMPDIR 隔离，不受同机其他会话影响）
# 只读：本测试不 push 到真实远端、不部署、不碰真实仓库。
#
# 跑法：bash scripts/tests/test_conflicts.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SW="${SL_TEST_SW:-$REPO_ROOT/scripts/session-wt.sh}"   # SL_TEST_SW=变异副本（自证测试有效）
# 分支名跟被测脚本的参数层保持一致（模板项目把 SL_DEV_BRANCH 改成 dev 时，测试要跟着传）
DEV="${SL_TEST_DEV:-kewang}"
MIRROR="${SL_TEST_MIRROR:-main}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

git_cfg() { git -c user.name=test -c user.email=t@example.com "$@"; }

# 裸远端 + hub（branch=kewang）+ 两个会话 worktree
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/hub" 2>/dev/null
cd "$TMP/hub" || exit 1
git symbolic-ref HEAD "refs/heads/$DEV"
echo base > README.md
echo x > x.txt
seq 1 100 > big.txt
echo stage > stage.txt
mkdir -p scripts && cp "$SW" scripts/session-wt.sh && chmod +x scripts/session-wt.sh
git_cfg add -A && git_cfg commit -qm base
git_cfg push -q origin "$DEV" && git_cfg push -q origin "$DEV:$MIRROR"
git_cfg worktree add -q "$TMP/wt-a" -b wt/a "$DEV"
git_cfg worktree add -q "$TMP/wt-b" -b wt/b "$DEV"

run_conflicts() {  # $1=会话名 → 输出到 $TMP/out.log；TMPDIR 独立，泄漏可判定
    ( cd "$TMP/hub" && mkdir -p "$TMP/tmp" && TMPDIR="$TMP/tmp" SL_WT_ROOT="$TMP" \
        ./scripts/session-wt.sh conflicts "$1" ) >"$TMP/out.log" 2>&1
}

# ── 1. 三种交集：a 未提交 × b 未提交/未推送 × hub 未提交 ──────────────
echo a-readme >> "$TMP/wt-a/README.md"
echo a-x >> "$TMP/wt-a/x.txt"
echo b-readme >> "$TMP/wt-b/README.md"
echo b-x >> "$TMP/wt-b/x.txt"
git_cfg -C "$TMP/wt-b" commit -qm "b: x 未推送" -- x.txt   # 只提交 x.txt，README 留未提交
echo b-new > "$TMP/wt-b/new.txt"
echo hub-readme >> "$TMP/hub/README.md"

if run_conflicts a; then
    if grep -q "会话 b" "$TMP/out.log" && grep -q "会话 hub" "$TMP/out.log" \
       && grep -q "README.md" "$TMP/out.log" && grep -q "x.txt" "$TMP/out.log"; then
        ok "冲突雷达：未提交 × 未提交/未推送提交/hub 在制品"
    else
        bad "冲突雷达交集不全：$(sed -n '1,12p' "$TMP/out.log" | tr '\n' ' ')"
    fi
else
    bad "冲突雷达执行失败（rc≠0）：$(tail -3 "$TMP/out.log")"
fi

# ── 2. 无交集 ──────────────────────────────────────────────────────
git_cfg -C "$TMP/wt-a" checkout -q -- README.md x.txt
echo only > "$TMP/wt-a/only-a.txt"
git_cfg -C "$TMP/hub" checkout -q -- README.md
if run_conflicts a && grep -q "无跨会话文件重叠" "$TMP/out.log"; then
    ok "冲突雷达：无交集时明确报「无重叠」"
else
    bad "无交集场景输出不符：$(sed -n '1,10p' "$TMP/out.log" | tr '\n' ' ')"
fi

# ── 3. origin 在分支点之后改过同一文件 → rebase 提示 ─────────────────
( cd "$TMP/hub" && echo up >> README.md && git_cfg commit -qam up \
    && git_cfg push -q origin "$DEV" ) >/dev/null 2>&1
echo mine >> "$TMP/wt-a/README.md"
if run_conflicts a && grep -q "origin/$DEV 在你分支之后" "$TMP/out.log"; then
    ok "冲突雷达：origin 已改同一文件（rebase 预警）"
else
    bad "origin 重叠未报出：$(sed -n '1,10p' "$TMP/out.log" | tr '\n' ' ')"
fi

# ── 4. 已提交的纯重命名：旧路径计入（去掉 --no-renames 会因 100% 相似度漏报）──
git_cfg -C "$TMP/wt-b" mv big.txt big2.txt
git_cfg -C "$TMP/wt-b" commit -qm "b: rename big"
echo touch >> "$TMP/wt-a/big.txt"
if run_conflicts a && grep -q "big.txt" "$TMP/out.log"; then
    ok "冲突雷达：已提交重命名的旧路径计入"
else
    bad "已提交重命名旧路径未计入：$(sed -n '1,10p' "$TMP/out.log" | tr '\n' ' ')"
fi

# ── 5. 暂存区重命名（R 在 X 位）：旧路径计入 ─────────────────────────
git_cfg -C "$TMP/wt-b" mv stage.txt stage2.txt        # 已暂存、未提交
echo again >> "$TMP/wt-a/stage.txt"
# 只看交集段（origin 预警段也会出现 README.md，整文件 grep 会把断言变成恒真）
run_conflicts a
_conflict_seg=$(sed '/· origin\//,$d' "$TMP/out.log")
if printf '%s' "$_conflict_seg" | grep -q "stage.txt"; then
    ok "冲突雷达：暂存区重命名的旧路径计入"
else
    bad "暂存重命名旧路径未计入：$(printf '%s' "$_conflict_seg" | tr '\n' ' ')"
fi

# ── 6. 双方同名未跟踪文件 ──────────────────────────────────────────
echo same > "$TMP/wt-a/same-new.txt"
echo same > "$TMP/wt-b/same-new.txt"
if run_conflicts a && grep -q "same-new.txt" "$TMP/out.log"; then
    ok "冲突雷达：双方同名未跟踪文件算交集"
else
    bad "同名未跟踪文件未报出：$(sed -n '1,10p' "$TMP/out.log" | tr '\n' ' ')"
fi

# ── 7. 有会话读不到（无共同祖先）→ 结论不完整，不得报「无重叠」──
_empty_tree=$(git -C "$TMP/hub" hash-object -t tree /dev/null)
_root=$(git_cfg -C "$TMP/hub" commit-tree "$_empty_tree" -m unrelated)
git_cfg -C "$TMP/hub" branch -f unrelated "$_root"
git_cfg -C "$TMP/hub" worktree add -q "$TMP/wt-u" unrelated
git_cfg -C "$TMP/hub" worktree add -q "$TMP/wt-c" -b wt/c "origin/$DEV"
if run_conflicts c && grep -q "结论不完整" "$TMP/out.log" \
   && ! grep -q "无跨会话文件重叠" "$TMP/out.log"; then
    ok "冲突雷达：读不到改动集时披露「结论不完整」"
else
    bad "读取失败被误报为无重叠：$(sed -n '1,12p' "$TMP/out.log" | tr '\n' ' ')"
fi

# ── 8. 归属校验：别的仓库的 /tmp/wt-<name> 不许读 ────────────────────
git_cfg init -q "$TMP/other"
( cd "$TMP/other" && echo o > o.txt && git_cfg add o.txt && git_cfg commit -qm o ) >/dev/null
git_cfg -C "$TMP/other" worktree add -q "$TMP/wt-foreign" --detach 2>/dev/null
if run_conflicts foreign; then
    bad "归属校验：竟读取了别的仓库的 worktree"
else
    grep -q "不是本仓库的 worktree" "$TMP/out.log" && ok "冲突雷达：拒绝跨仓读取" \
        || bad "被拒但原因不符：$(tail -2 "$TMP/out.log")"
fi

# ── 9. 临时目录不残留（TMPDIR 独立，不受同机其他会话影响）──────────────
_leak=$(ls -A "$TMP/tmp" 2>/dev/null | wc -l | tr -d ' ')
if [ "$_leak" = "0" ]; then ok "冲突雷达：临时目录已清理"; else bad "残留 ${_leak} 个临时目录：$(ls -A "$TMP/tmp")"; fi

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
