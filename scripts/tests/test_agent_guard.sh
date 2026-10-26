#!/usr/bin/env bash
# agent-guard 行为回归（2026-10-24）。
#
# 真跑 scripts/agent-guard.py（模拟 Claude Code PreToolUse 的 stdin JSON），验证：
#   R1 主 checkout 编辑被拒（绝对/相对/软链指向）、worktree 放行、别的仓库放行
#   R2 hub 整树覆盖型 git 被拒、worktree 放行、只读命令放行
#   R3 commit --no-verify 被拒（-m 值恰为 -n 时不得误伤）
#   R4 hub 里 git commit 被拒（含 cd 进 hub / git -C hub）、worktree 放行
#   R5 SKIP_PREPUSH_CHECK=1 的 push 被拒、只读提及放行
#   R6 外部预设 DEPLOY_IN_WORKTREE=1 被拒、grep 提及放行
#   失败模式：坏 JSON / 未知工具 / 非仓库 cwd 一律放行（exit 0）
#   逃生舱：SL_ALLOW_* 环境变量与命令行内联变量生效
# 不依赖网络、不碰真实仓库。
#
# 跑法：bash scripts/tests/test_agent_guard.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/agent-guard.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

git_cfg() { git -c user.name=test -c user.email=t@example.com -c init.defaultBranch=main "$@"; }

# 主仓 + 链接 worktree + 另一个仓库（用于「不误伤别的仓库」）
mkdir -p "$TMP/repo" "$TMP/other"
git_cfg init -q "$TMP/repo"
( cd "$TMP/repo" && mkdir -p scripts && echo "#!/bin/sh" > scripts/session-wt.sh \
    && echo base > a.txt && git add a.txt scripts && git commit -qm base ) >/dev/null
git -C "$TMP/repo" worktree add -q "$TMP/wt" -b work
mkdir -p "$TMP/wt/sub"
git_cfg init -q "$TMP/other"
( cd "$TMP/other" && echo o > o.txt && git add o.txt && git commit -qm base ) >/dev/null
ln -sfn "$TMP/repo" "$TMP/wt/link-to-hub"

HUB="$TMP/repo"; WT="$TMP/wt"; OTHER="$TMP/other"

payload() {  # $1=tool $2=key $3=value $4=cwd
    python3 - "$@" <<'PY'
import json, sys
tool, key, val, cwd = sys.argv[1:5]
print(json.dumps({"tool_name": tool, "tool_input": {key: val}, "cwd": cwd}))
PY
}

expect_rc() {  # $1=label $2=期望退出码 $3=payload $4=可选 stderr 关键字 $5=可选 env 赋值
    local got=0
    if [ -n "${5:-}" ]; then
        printf '%s' "$3" | env $5 python3 "$GUARD" >/dev/null 2>"$TMP/err" || got=$?
    else
        printf '%s' "$3" | python3 "$GUARD" >/dev/null 2>"$TMP/err" || got=$?
    fi
    if [ "$got" != "$2" ]; then
        bad "$1（rc=$got 期望 $2）: $(head -2 "$TMP/err" | tr '\n' ' ')"
    elif [ -n "${4:-}" ] && ! grep -q "$4" "$TMP/err"; then
        bad "$1（被拒但原因不符）: $(head -2 "$TMP/err" | tr '\n' ' ')"
    elif [ "$2" = "0" ] && grep -qE "内部异常|Traceback" "$TMP/err"; then
        bad "$1（放行但走了 fail-open 异常路径）: $(head -2 "$TMP/err" | tr '\n' ' ')"
    else
        ok "$1"
    fi
}

# ── R1 主 checkout 编辑 ─────────────────────────────────────────────
expect_rc "R1 hub 绝对路径编辑被拒" 2 "$(payload Edit file_path "$HUB/a.txt" "$HUB")" "主 checkout"
expect_rc "R1 相对路径按 cwd 解析后拒绝" 2 "$(payload Edit file_path "a.txt" "$HUB")" "主 checkout"
expect_rc "R1 软链指向 hub 也被拒（realpath）" 2 "$(payload Write file_path "$WT/link-to-hub/a.txt" "$WT")" "主 checkout"
expect_rc "R1 worktree 内编辑放行" 0 "$(payload Edit file_path "$WT/a.txt" "$WT")"
expect_rc "R1 worktree 相对路径放行" 0 "$(payload Edit file_path "sub/x.txt" "$WT")"
expect_rc "R1 别的仓库放行（不误伤）" 0 "$(payload Edit file_path "$OTHER/o.txt" "$HUB")"
expect_rc "R1 非仓库路径放行" 0 "$(payload Write file_path "$TMP/scratch.txt" "$HUB")"
expect_rc "R1 SL_ALLOW_HUB_EDIT=1 放行" 0 "$(payload Edit file_path "$HUB/a.txt" "$HUB")" "" "SL_ALLOW_HUB_EDIT=1"
expect_rc "R1 SL_GUARD_BYPASS=1 全关" 0 "$(payload Edit file_path "$HUB/a.txt" "$HUB")" "" "SL_GUARD_BYPASS=1"

# ── R4 hub 提交 ────────────────────────────────────────────────────
expect_rc "R4 hub 里 git commit 被拒" 2 "$(payload Bash command "git commit -m x" "$HUB")" "git commit"
expect_rc "R4 cd 进 hub 后提交被拒（跟踪 cd）" 2 "$(payload Bash command "cd $HUB && git commit -m x" "$WT")" "git commit"
expect_rc "R4 git -C hub 提交被拒" 2 "$(payload Bash command "git -C $HUB commit -m x" "$WT")" "git commit"
expect_rc "R4 worktree 里提交放行" 0 "$(payload Bash command "git commit -m x" "$WT")"
expect_rc "R4 子目录提交放行" 0 "$(payload Bash command "git commit -m x" "$WT/sub")"
expect_rc "R4 SL_ALLOW_HUB_COMMIT=1 放行" 0 "$(payload Bash command "SL_ALLOW_HUB_COMMIT=1 git commit -m x" "$HUB")"
expect_rc "R4 heredoc 正文里的 git commit 不误判" 0 "$(payload Bash command "cat > $WT/x.sh <<'EOF'
git commit -m y
EOF" "$HUB")"

# ── R3 --no-verify ────────────────────────────────────────────────
expect_rc "R3 --no-verify 被拒" 2 "$(payload Bash command "git commit --no-verify -m x" "$WT")" "no-verify"
expect_rc "R3 -n 短选项被拒" 2 "$(payload Bash command "git commit -n -m x" "$WT")" "no-verify"
expect_rc "R3 组合短选项 -nm 被拒" 2 "$(payload Bash command "git commit -nm x" "$WT")" "no-verify"
expect_rc "R3 -m 的值恰为 -n 不误伤" 0 "$(payload Bash command "git commit -m \"-n\"" "$WT")"
expect_rc "R3 SL_ALLOW_NO_VERIFY=1 放行" 0 "$(payload Bash command "SL_ALLOW_NO_VERIFY=1 git commit --no-verify -m x" "$WT")"

# ── R5 SKIP_PREPUSH_CHECK ─────────────────────────────────────────
expect_rc "R5 SKIP_PREPUSH_CHECK=1 push 被拒" 2 "$(payload Bash command "SKIP_PREPUSH_CHECK=1 git push origin work" "$WT")" "pre-push"
expect_rc "R5 只读提及不误判（grep）" 0 "$(payload Bash command "grep -rn SKIP_PREPUSH_CHECK=1 scripts/" "$WT")"
expect_rc "R5 普通 push 放行" 0 "$(payload Bash command "git push origin work" "$WT")"
expect_rc "R5 SL_ALLOW_SKIP_PREPUSH=1 放行" 0 "$(payload Bash command "SL_ALLOW_SKIP_PREPUSH=1 SKIP_PREPUSH_CHECK=1 git push origin work" "$WT")"

# ── R6 DEPLOY_IN_WORKTREE ─────────────────────────────────────────
expect_rc "R6 DEPLOY_IN_WORKTREE=1 被拒" 2 "$(payload Bash command "DEPLOY_IN_WORKTREE=1 ./scripts/deploy.sh -w" "$WT")" "隔离壳"
expect_rc "R6 env 包装也拦" 2 "$(payload Bash command "env DEPLOY_IN_WORKTREE=1 ./scripts/deploy.sh" "$WT")" "隔离壳"
expect_rc "R6 grep 提及不误判" 0 "$(payload Bash command "grep -n DEPLOY_IN_WORKTREE=1 scripts/deploy.sh" "$WT")"

# ── R2 hub 整树覆盖型 git ─────────────────────────────────────────
expect_rc "R2 hub git checkout -- . 被拒" 2 "$(payload Bash command "git checkout -- ." "$HUB")" "在制品"
expect_rc "R2 hub git reset --hard 被拒" 2 "$(payload Bash command "git reset --hard HEAD~1" "$HUB")" "在制品"
expect_rc "R2 hub git clean -fd 被拒" 2 "$(payload Bash command "git clean -fd" "$HUB")" "在制品"
expect_rc "R2 hub bare git stash 被拒" 2 "$(payload Bash command "git stash" "$HUB")" "在制品"
expect_rc "R2 hub git stash list 放行（只读）" 0 "$(payload Bash command "git stash list" "$HUB")"
expect_rc "R2 worktree 里 checkout -- . 放行" 0 "$(payload Bash command "git checkout -- ." "$WT")"
expect_rc "R2 hub 单文件 checkout 放行" 0 "$(payload Bash command "git checkout -- a.txt" "$HUB")"
expect_rc "R2 SL_ALLOW_HUB_DESTRUCTIVE=1 放行" 0 "$(payload Bash command "SL_ALLOW_HUB_DESTRUCTIVE=1 git checkout -- ." "$HUB")"

# ── 审查补钉（2026-10-24 一轮审查 P1/P2 回归）─────────────────────
expect_rc "P1 git push --no-verify 被拒" 2 "$(payload Bash command "git push --no-verify origin work" "$WT")" "pre-push"
expect_rc "P1 push 的 -n 是 dry-run，不误判" 0 "$(payload Bash command "git push -n origin work" "$WT")"
expect_rc "P1 hub git checkout -f 被拒" 2 "$(payload Bash command "git checkout -f main" "$HUB")" "在制品"
expect_rc "P1 hub git switch -f 被拒" 2 "$(payload Bash command "git switch -f main" "$HUB")" "在制品"
expect_rc "P1 hub switch --discard-changes 被拒" 2 "$(payload Bash command "git switch --discard-changes main" "$HUB")" "在制品"
expect_rc "P1 worktree 里 checkout -f 放行" 0 "$(payload Bash command "git checkout -f main" "$WT")"
expect_rc "P2 -S -n 仍认出 --no-verify" 2 "$(payload Bash command "git commit -S -n -m x" "$WT")" "no-verify"
expect_rc "P2 cd -- <hub> 被跟踪" 2 "$(payload Bash command "cd -- $HUB && git commit -m x" "$WT")" "git commit"
expect_rc "P2 time -p git 前缀不吞 git" 2 "$(payload Bash command "time -p git commit -m x" "$HUB")" "git commit"
expect_rc "P2 git commit --help 放行（只读）" 0 "$(payload Bash command "git commit --help" "$HUB")"
expect_rc "P2 跨段 env 不污染前一条命令" 0 "$(payload Bash command "git push origin work && SKIP_PREPUSH_CHECK=1 true" "$WT")"
expect_rc "P2 带 << 的 echo 不误当 heredoc" 2 "$(payload Bash command "echo \"a << b\"
git commit -m x" "$HUB")" "git commit"
expect_rc "P2 GIT_DIR 前缀指向 hub 被拒" 2 "$(payload Bash command "GIT_DIR=$HUB/.git git commit -m x" "$WT")" "git commit"

# 非 SevenLocks 仓库（无 scripts/session-wt.sh 标记）：本层不介入
mkdir -p "$TMP/plain"
git_cfg init -q "$TMP/plain"
( cd "$TMP/plain" && echo p > p.txt && git add p.txt && git commit -qm base ) >/dev/null
expect_rc "P2 非 SevenLocks 仓库不介入（无标记）" 0 "$(payload Edit file_path "$TMP/plain/p.txt" "$TMP/plain")"

# ── 失败模式 / 其他工具 ───────────────────────────────────────────
expect_rc "坏 JSON 放行（fail-open）" 0 'not-json'
expect_rc "空对象放行" 0 '{}'
expect_rc "未知工具放行（Read）" 0 "$(payload Read file_path "$HUB/a.txt" "$HUB")"
expect_rc "非仓库 cwd 放行" 0 "$(payload Edit file_path "$TMP/scratch.txt" "$TMP")"

echo ""
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
