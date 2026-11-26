#!/usr/bin/env bash
# session-wt gc-dirs 行为回归（2026-11-26，v1.19.0/v1.19.1）。
#
# 覆盖两档判据的「不删」边界（删除错误比留垃圾严重得多）：
#   1) 默认档：含普通文件的空壳 → 保留（v1.19.1；空壳无 .git，归属不可判）
#   2) 默认档：只有空目录骨架的壳 → 删除
#   3) 未纳管档：别的项目的 .git 指针目录 → 跳过（共用 WT_ROOT 时的首要风险）
#   4) 未纳管档：本仓 clean 且无未推提交的克隆 → 删除
#   5) 未纳管档：本仓有未提交改动的克隆 → 保留
# 只读：临时目录内自造夹具，不碰真实仓库与真实 /tmp/wt-*。
#
# 跑法：bash scripts/tests/test_gc_dirs.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SW="${SL_TEST_SW:-$REPO_ROOT/scripts/session-wt.sh}"
AGE_DAYS="$(sed -n 's/^SL_PRUNE_AGE_DAYS=\([0-9]*\).*/\1/p' "$SW" 2>/dev/null | head -1)"
AGE_DAYS="${AGE_DAYS:-3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# 夹具根（SL_WT_ROOT 直接指向它，目录名必须 wt-*）
ROOT="$TMP/wtroot"; mkdir -p "$ROOT"
OLD_STAMP=$(date -v-"$((AGE_DAYS+2))"d +%Y%m%d0000 2>/dev/null || date -d "-$((AGE_DAYS+2)) days" +%Y%m%d0000)
age_dir() { find "$1" -exec touch -t "$OLD_STAMP" {} + 2>/dev/null; touch -t "$OLD_STAMP" "$1" 2>/dev/null; }

# 1) 含文件的空壳
mkdir -p "$ROOT/wt-shell-withfile/sub"; echo "wip" > "$ROOT/wt-shell-withfile/sub/wip.txt"; age_dir "$ROOT/wt-shell-withfile"
# 2) 纯骨架空壳（只有目录）
mkdir -p "$ROOT/wt-shell-empty/a/b"; : > "$ROOT/wt-shell-empty/a/.keep"; rm -f "$ROOT/wt-shell-empty/a/.keep"; age_dir "$ROOT/wt-shell-empty"
# 3) 别的项目的 worktree 指针
mkdir -p "$TMP/other/.git/worktrees/x" "$ROOT/wt-other"; printf 'gitdir: %s\n' "$TMP/other/.git/worktrees/x" > "$ROOT/wt-other/.git"; age_dir "$ROOT/wt-other"
# 4/5) 本仓克隆（origin 与被测仓相同）+ 远端引用（模拟已推送）
MY_ORIGIN=$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || echo "local://test")
mk_clone() {
    local d="$1"; git init -q "$d"
    git -C "$d" remote add origin "$MY_ORIGIN"
    echo a > "$d/f.txt"; git -C "$d" add -A
    git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init
    git -C "$d" update-ref refs/remotes/origin/main HEAD
    age_dir "$d"
}
mk_clone "$ROOT/wt-mine-clean"
mk_clone "$ROOT/wt-mine-dirty"; echo x > "$ROOT/wt-mine-dirty/untracked.txt"; age_dir "$ROOT/wt-mine-dirty"

run_gc() { SL_WT_ROOT="$ROOT" bash "$SW" gc-dirs "$@" 2>&1; }

OUT=$(run_gc --yes --unmanaged)

grep -q "wt-shell-withfile" <<<"$OUT" && grep -q "保留: .*wt-shell-withfile" <<<"$OUT" \
    && ok "默认档：含文件的空壳保留" || bad "默认档：含文件的空壳被当作候选/删除"
[ -f "$ROOT/wt-shell-withfile/sub/wip.txt" ] && ok "默认档：含文件空壳的文件仍在" || bad "默认档：含文件空壳被删（数据丢失）"
[ ! -d "$ROOT/wt-shell-empty" ] && ok "默认档：纯骨架空壳已删" || bad "默认档：纯骨架空壳未删"
[ -d "$ROOT/wt-other" ] && ok "未纳管档：别的项目目录未动" || bad "未纳管档：删了别的项目目录"
[ ! -d "$ROOT/wt-mine-clean" ] && ok "未纳管档：本仓 clean 克隆已删" || bad "未纳管档：本仓 clean 克隆未删"
[ -d "$ROOT/wt-mine-dirty" ] && ok "未纳管档：有未提交改动的本仓克隆保留" || bad "未纳管档：删了有改动的克隆"

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
