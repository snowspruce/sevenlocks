#!/bin/bash
# sevenlocks-v1.1 · push-mine.sh —— 共享仓库多会话并发下，只把【本会话的一个提交】
# 安全推上远端分支（L3 推送层通用件）。
# 上游真源：上游项目 scripts/push-mine.sh ——通用逻辑升级照 diff 同步到上游，勿魔改本副本。
#
# 背景：多会话各自提交 → 本地与远端长期分叉。直接 push 撞 non-fast-forward；整线
# rebase 后推会把别人的未推提交一起发布。本脚本在临时 worktree 里只重放指定提交
# （默认 HEAD）到远端之上再推——不碰别人提交、不碰在制品。并发推送靠 git 远端原子性
# 互斥，无需额外锁。
#
# 用法：
#   ./scripts/push-mine.sh                  # 推 HEAD
#   ./scripts/push-mine.sh <commit>         # 推指定提交
#   ./scripts/push-mine.sh <commit> <branch># 推到指定远端分支（默认 DEV_BRANCH）
#   DRY_RUN=1 ./scripts/push-mine.sh …      # 走完重放但不真推（预检）
#
# 幂等双检：提交已在远端祖先链 / 补丁 patch-id 等价 → 直接退出 0。
# 冲突：rebase 失败保留 worktree 现场，打印手工续作命令。竞态：push 被拒重跑即可。
# ⚠️ bash 3.2 多字节怪癖：字符串里 ${VAR} 必须带花括号——裸 $VAR 紧跟全角标点会把
#    后续字节粘进变量名（unbound variable 实证）。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ===== 参数层 =====
SL_DEV_BRANCH="kewang"    # 默认推送目标
SL_MIRROR_BRANCH="main"   # 生产镜像分支（推送成功后自动 FF 同步；无镜像置 ""）
# ==================

BRANCH="${2:-$SL_DEV_BRANCH}"
if [ -n "$SL_MIRROR_BRANCH" ] && [ "$BRANCH" = "$SL_MIRROR_BRANCH" ]; then
    echo "ERROR: ${SL_MIRROR_BRANCH}=生产镜像分支——个人提交不应直推；默认推 ${SL_DEV_BRANCH}，镜像由本脚本自动同步"
    exit 1
fi

cd "$REPO_ROOT"
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}") || { echo "ERROR: cannot resolve commit ${1:-HEAD}"; exit 1; }
git fetch origin "$BRANCH" --quiet || { echo "ERROR: fetch origin/${BRANCH} failed"; exit 1; }

# 幂等①：提交本身已在远端祖先链上
if git merge-base --is-ancestor "$SHA" "origin/$BRANCH" 2>/dev/null; then
    echo "OK: ${SHA:0:8} 已在 origin/${BRANCH} 祖先链上，无需推送"
    exit 0
fi
# 幂等②：补丁等价检查（'-' 前缀 = 远端已有等价提交）；空输出 = 空提交等 cherry 跳过
# 的情形，放行走重放推送（空提交无法按 patch-id 判重——空提交别当 CI 触发标记用）
ch=$(git cherry "origin/$BRANCH" "$SHA" "$SHA^" 2>/dev/null | head -1 || true)
case "$ch" in
    -*) echo "OK: ${SHA:0:8} 的补丁已在 origin/${BRANCH}（等价提交存在），无需推送"; exit 0 ;;
    +*|'') : ;;
    *)  echo "ERROR: git cherry 输出异常: ${ch:-empty}"; exit 1 ;;
esac

WT=$(mktemp -d /tmp/push-mine.XXXXXX) && rmdir "$WT"
cleanup() { git worktree remove --force "$WT" 2>/dev/null || true; }
git worktree add --detach "$WT" "$SHA" --quiet
trap cleanup EXIT

if ! (cd "$WT" && git rebase --onto "origin/$BRANCH" "$SHA^" "$SHA"); then
    trap - EXIT   # 保留现场供手工解决
    echo "ERROR: rebase 冲突。手工续作："
    echo "  cd $WT && 解决冲突 && git rebase --continue && git push origin HEAD:refs/heads/${BRANCH} && git worktree remove $WT"
    exit 1
fi
NEW_SHA=$(git -C "$WT" rev-parse HEAD)
if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "DRY_RUN OK: 重放成功 ${SHA:0:8} -> ${NEW_SHA:0:8}（未推送）"
    exit 0
fi
if ! (cd "$WT" && git push origin "HEAD:refs/heads/$BRANCH"); then
    echo "ERROR: push 被拒（fetch 之后 origin/${BRANCH} 又被推进）——重跑本脚本即可"
    exit 1
fi
echo "OK: 已推送 ${SHA:0:8} -> ${NEW_SHA:0:8}（仅此一个提交 -> origin/${BRANCH}）"
# 镜像自动同步（与 session-wt push 同款）：非 FF 天然被拒不强推；失败不阻塞主流程。
if [ -n "$SL_MIRROR_BRANCH" ] && [ "$BRANCH" = "$SL_DEV_BRANCH" ]; then
    if (cd "$WT" && git push origin "HEAD:refs/heads/$SL_MIRROR_BRANCH"); then
        echo "镜像: ${SL_MIRROR_BRANCH} 已 FF 同步到 ${NEW_SHA:0:8}"
    else
        echo "WARN: ${SL_MIRROR_BRANCH} 镜像 FF 同步未成——确认后手动 git push origin origin/${SL_DEV_BRANCH}:${SL_MIRROR_BRANCH}"
    fi
fi
