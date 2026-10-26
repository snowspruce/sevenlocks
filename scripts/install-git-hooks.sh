#!/usr/bin/env bash
# 安装仓库级 git 钩子（pre-commit hub 守卫 / pre-merge-commit / pre-push 落后守卫）。
#
# 为什么不改 core.hooksPath：本机 core.hooksPath 常已指向 .git/hooks，里面有现役的
# pre-commit（挡 macOS 元数据文件）与 post-commit（Qoder 追踪）。改成指向仓库目录会
# 让它们静默失效。这里只把**本仓管理的钩子**复制进 hooks 目录，其余钩子不动；
# 同名钩子若已存在且不是本仓装的，先保留为 `<hook>.local`，由新钩子链式调用。
#
# 为什么不盲目跟随 core.hooksPath：若它指向跨仓共享目录（如 ~/.githooks），装上后
# 会让**所有使用该目录的仓库**都被本仓的 hub 守卫拒绝。检测到非本仓 hooks 目录时
# 默认拒绝（确认可接受后 SL_ALLOW_SHARED_HOOKS=1 重跑）。
#
# 为什么复制而不是软链：软链指向某个 worktree 里的脚本，worktree 被 clean/prune 后
# 会变成断链，git 执行钩子直接报错，等于把提交/推送卡死。
#
# 用法：./scripts/install-git-hooks.sh [--check]
#   重复执行即可更新（内容不同会先备份旧文件）。
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
HOOKS_DIR="$(git rev-parse --path-format=absolute --git-path hooks)"
SRC_DIR="$ROOT/scripts/hooks"
MARKER="sevenlocks-managed"
MANAGED="pre-commit pre-merge-commit pre-push"

# core.hooksPath 指向本仓 .git/hooks 之外 → 会跨仓生效，默认拒绝
_hp=$(git config --get core.hooksPath 2>/dev/null || true)
if [ -n "$_hp" ]; then
    case "$_hp" in
        /*) _hp_abs="$_hp" ;;
        *)  _hp_abs="$ROOT/$_hp" ;;
    esac
    if [ "$(cd "$_hp_abs" 2>/dev/null && pwd -P)" != "$(cd "$COMMON_DIR/hooks" 2>/dev/null && pwd -P)" ] \
       && [ "${SL_ALLOW_SHARED_HOOKS:-0}" != "1" ]; then
        echo "ERROR: core.hooksPath=${_hp} 指向本仓 .git/hooks 之外——守卫会作用到所有使用该目录的仓库" >&2
        echo "       确认可接受后：SL_ALLOW_SHARED_HOOKS=1 $0" >&2
        exit 1
    fi
fi

[ -d "$SRC_DIR" ] || { echo "ERROR: 找不到 ${SRC_DIR}（在仓库根目录执行？）"; exit 1; }

# 预检全部源文件：避免「装了一半 → 旧钩子已被移走 → 新钩子没装上」的裸奔状态
for h in $MANAGED; do
    [ -f "$SRC_DIR/$h" ] || { echo "ERROR: 缺少 ${SRC_DIR}/${h}（${MANAGED// /、} 必须齐全）"; exit 1; }
done

check_mode=0
[ "${1:-}" = "--check" ] && check_mode=1

if [ "$check_mode" = "1" ]; then
    stale=""
    for h in $MANAGED; do
        src="$SRC_DIR/$h"
        dst="$HOOKS_DIR/$h"
        if [ ! -f "$dst" ] || [ ! -x "$dst" ] || ! cmp -s "$src" "$dst"; then
            stale="${stale} $h"
        fi
    done
    if [ -z "$stale" ]; then
        echo "OK: 仓库钩子已安装且是最新（${HOOKS_DIR}）"
        exit 0
    fi
    echo "待安装/待更新:${stale}（${HOOKS_DIR}）"
    exit 1
fi

mkdir -p "$HOOKS_DIR"
for h in $MANAGED; do
    src="$SRC_DIR/$h"
    dst="$HOOKS_DIR/$h"
    chmod +x "$src"

    if [ -e "$dst" ] && ! grep -q "$MARKER" "$dst" 2>/dev/null; then
        # 本机既有同名钩子：保留并交给新钩子链式调用（否则会被静默顶掉）
        if [ ! -e "$dst.local" ]; then
            mv "$dst" "$dst.local"
            echo "已保留本机钩子 → ${dst}.local（由新钩子链式调用）"
        else
            bak="${dst}.bak-$(date +%Y%m%d%H%M%S)-$$"
            mv "$dst" "$bak"
            echo "已备份未管理的钩子 → ${bak}（${dst}.local 已存在，不覆盖；该钩子不会被链式调用）"
        fi
    elif [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
        bak="${dst}.bak-$(date +%Y%m%d%H%M%S)-$$"
        mv "$dst" "$bak"
        echo "已备份旧版本 → ${bak}"
    fi

    # 先删再拷：对既有 symlink，cp 会改写链接目标并保留链接（worktree 清理后断链）
    rm -f "$dst"
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "OK: ${h} 已安装 → ${dst}"
done

echo "    保护分支：${PREPUSH_PROTECTED:-kewang main}（PREPUSH_PROTECTED 覆盖）"
echo "    逃生舱：SKIP_PREPUSH_CHECK=1 git push … / SL_ALLOW_HUB_COMMIT=1 git commit …"
echo ""
echo "⚠️  注意：hooks 目录被所有 worktree 共用，装一次即可全仓生效。"
