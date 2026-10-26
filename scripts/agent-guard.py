#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""agent-guard —— 编辑时拦截（Claude Code PreToolUse 关卡，2026-10-24）

定位：**增强层**。跨 agent 的底线仍是 git 钩子（hub 提交 / 落后推送）与部署脚本自身的
闸；本脚本把同一批规则前移到工具调用之前——等到 commit/push 才失败，代价是一整轮工具
调用与上下文；编辑前失败，代价是一句话。只对挂了本钩子的 agent 生效（Claude Code），
ZCode / Codex / 手工终端靠 git 钩子兜底。只在装有 SevenLocks 的仓库内生效
（会话根有 scripts/session-wt.sh）——避免在 submodule / 普通第三方仓里误拦。

拦截规则：
  R1 主 checkout（hub）里的 Edit/Write/MultiEdit/NotebookEdit —— hub 只作只读镜像
  R2 hub 里整树覆盖型 git（checkout/switch 的 -f、restore .、reset --hard、clean -f、
     stash）—— 会抹掉其他会话的在制品（实录事故：git restore 抹掉另一会话的改动）
  R3 git commit --no-verify / git push --no-verify —— 跳过提交/推送钩子
  R4 在 hub 里 git commit —— 与 pre-commit 钩子同判据，只是更早
  R5 SKIP_PREPUSH_CHECK=1 的 git push —— 跳过落后 / 非快进 / 删保护分支守卫
  R6 外部预设 DEPLOY_IN_WORKTREE=1 —— 绕过部署锁 + 隔离树 + 单调前进闸

判据：git-dir == git-common-dir ⇒ 主 checkout（链接 worktree 的 git-dir 在
common/worktrees/ 下）；路径先 realpath（防软链绕进 hub）；只对「与当前会话同仓库」的
目标生效。命令解析跟踪 cd / -C / --git-dir / GIT_DIR / env 前缀 / export / heredoc；
`-m` 等带值选项的值不会被误当标记。

逃生舱（编辑类工具无法内联设变量，只能启动期给）：
  SL_GUARD_BYPASS=1           全关（自担风险）
  SL_ALLOW_HUB_EDIT=1         允许改 hub
  SL_ALLOW_HUB_DESTRUCTIVE=1  允许 hub 整树覆盖型 git
命令行内联（与 git 钩子同名）：SL_ALLOW_HUB_COMMIT=1 / SL_ALLOW_NO_VERIFY=1 /
  SL_ALLOW_SKIP_PREPUSH=1

已知不覆盖（启发式边界，别当写保护）：
  - Bash 里的重定向/写入（`echo > hub/f`、`sed -i`、`cp`、python 写文件）
  - 嵌套 shell（`bash -c "…"`、`eval`）与变量拼出的命令
  - hub 里 git merge / revert / cherry-pick（由 pre-commit / pre-merge-commit 兜底）
  - 从一个 worktree 操作另一个会话的 worktree（只有 `session-wt conflicts` 雷达提示）

失败模式：任何内部错误（坏 JSON / 取不到仓库 / git 太老）一律放行（exit 0），只把原因
打到 stderr——守门层不能把正常开发卡死。
"""

import json
import os
import re
import shlex
import subprocess
import sys

GIT = os.environ.get("SL_GIT", "git")
TOOL_PATH_KEY = {
    "Edit": "file_path",
    "MultiEdit": "file_path",
    "Write": "file_path",
    "NotebookEdit": "notebook_path",
}
# 仓库标记：会话根存在它才认为这是 SevenLocks 项目（否则本层不介入）
MARKER = os.path.join("scripts", "session-wt.sh")


def note(msg):
    sys.stderr.write("agent-guard: %s\n" % msg)


def deny(title, lines):
    sys.stderr.write("\n❌ agent-guard 拒绝：%s\n\n" % title)
    for line in lines:
        sys.stderr.write(("   " + line + "\n") if line else "\n")
    sys.stderr.write("\n（增强层：git 钩子仍是跨 agent 的底线；规则见 scripts/agent-guard.py）\n")
    sys.exit(2)


def _run(args, cwd, env_extra=None):
    env = None
    if env_extra:
        env = os.environ.copy()
        env.update({k: v for k, v in env_extra.items() if v is not None})
    try:
        proc = subprocess.run(
            args, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10
        )
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", "replace")


def _join(base, path):
    path = os.path.expanduser(path)
    return os.path.normpath(path if os.path.isabs(path) else os.path.join(base, path))


def repo_of(git_globals, cwd, env_extra=None):
    """返回 (git_dir, common_dir) 的真实路径；失败返回 None（调用方放行）。"""
    out = _run(
        [GIT] + list(git_globals)
        + ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
        cwd,
        env_extra,
    )
    if out is not None:
        lines = [line.strip() for line in out.splitlines() if line.strip()]
        if len(lines) >= 2:
            return os.path.realpath(lines[0]), os.path.realpath(lines[1])
    # 回退（git < 2.31 不认 --path-format）：输出可能相对，按 -C 生效后的 cwd 补全
    out = _run(
        [GIT] + list(git_globals) + ["rev-parse", "--git-dir", "--git-common-dir"],
        cwd,
        env_extra,
    )
    if out is None:
        return None
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if len(lines) < 2:
        return None
    base = cwd
    index = 0
    while index < len(git_globals):
        if git_globals[index] == "-C" and index + 1 < len(git_globals):
            base = _join(base, git_globals[index + 1])
        index += 1
    return (
        os.path.realpath(_join(base, lines[0])),
        os.path.realpath(_join(base, lines[1])),
    )


def sevenlocks_active(cwd):
    top = _run([GIT, "rev-parse", "--show-toplevel"], cwd)
    if not top:
        return False
    return os.path.isfile(os.path.join(top.strip(), MARKER))


def is_hub_of(repo, me):
    """repo 是本会话仓库的主 checkout？"""
    return bool(repo) and bool(me) and repo[0] == repo[1] and repo[1] == me[1]


def nearest_dir(path):
    cur = path if os.path.isdir(path) else os.path.dirname(path)
    while cur:
        if os.path.isdir(cur):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent
    return None


def check_path_tool(tool, tool_input, cwd, me):
    key = TOOL_PATH_KEY.get(tool)
    raw = tool_input.get(key) if key else None
    if not isinstance(raw, str) or not raw:
        return
    target = raw if os.path.isabs(raw) else os.path.join(cwd, raw)
    target = os.path.realpath(target)
    probe = nearest_dir(target)
    if not probe:
        return
    repo = repo_of([], probe)
    if not repo or repo[1] != me[1]:
        return  # 不在仓库内 / 是另一个仓库
    if repo[0] != repo[1]:
        return  # 链接 worktree：正常编码路径
    if os.environ.get("SL_ALLOW_HUB_EDIT") == "1":
        note("SL_ALLOW_HUB_EDIT=1，放行 hub 编辑：%s" % raw)
        return
    deny(
        "目标是主 checkout（hub）——hub 只作只读镜像，不是编码区",
        [
            "目标: %s" % target,
            "",
            "正确路径：",
            "  ./scripts/session-wt.sh start <name>       # 已在会话 worktree 内则跳过",
            "  # 改 /tmp/wt-<name>/ 下的同名文件（工具用该目录的绝对路径）",
            "改动已在 hub 工作区里（归属你的那部分）：",
            "  ./scripts/session-wt.sh adopt <name> -- <你的路径…>",
            "确实要改 hub（收口等特殊场景）：以 SL_ALLOW_HUB_EDIT=1 启动 Claude",
        ],
    )


# ── shell 命令解析（尽力而为：漏判无害，误判才是成本）─────────────────────
OPS = {"&&", "||", ";", "|", "&", "|&", ";;"}
PUNCT = set("();<>|&")
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# 包装命令：# 无值选项 / 带值选项（按命令区分，不能一律「跳过下一个 token」——
# `time -p git …` 的 -p 不取值，一刀切会把 git 当值吞掉）
WRAPPER_FLAGS = {
    "sudo": ({"-E", "-H", "-n", "-S", "-k"}, {"-u", "-g", "-p", "-C", "-h", "-U", "-r", "-t"}),
    "env": ({"-i", "-0", "-v", "--ignore-environment"}, {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"}),
    "command": ({"-p", "-v", "-V"}, set()),
    "time": ({"-p", "-v", "-a"}, {"-f", "-o"}),
    "exec": ({"-c", "-l"}, {"-a"}),
    "nohup": (set(), set()),
    "builtin": (set(), set()),
}
GIT_OPTS_WITH_VALUE = {
    "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env",
    "--super-prefix", "--exec-path",
}
COMMIT_OPTS_WITH_VALUE = {
    "-m", "--message", "-F", "--file", "-C", "--reuse-message", "-c",
    "--reedit-message", "-t", "--template", "--author", "--date", "--cleanup",
    "--trailer",
}
COMMIT_SHORT_WITH_VALUE = "mFCct"   # -S/-u 不在此列（值只能粘连或不取值）
WHOLE_TREE_PATHSPECS = {".", "./", "*", ":/", ":(top)"}
DESTRUCTIVE = {"checkout", "switch", "restore", "reset", "clean", "stash"}


def strip_heredocs(cmd):
    """去掉 heredoc 正文（正文里出现 git commit 不该被当成命令）。

    只认「定界符在行尾」的标准写法：`cat > f <<'EOF'`。`echo "a << b"` 这类
    不是 heredoc——不锚行尾会把后续行整段吞掉，反而漏掉真正的命令。
    """
    out = []
    pending = []
    for line in cmd.splitlines():
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        match = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1\s*$", line)
        out.append(re.sub(r"<<-?\s*(['\"]?)[A-Za-z_][A-Za-z0-9_]*\1\s*$", "", line))
        if match:
            pending.append(match.group(2))
    return "\n".join(out)


def tokenize(line):
    try:
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except Exception:
        return line.split()


def split_prefix(seg):
    """拆掉段首的 env 赋值与包装命令 → (赋值字典, 余下 tokens, 是否 export)。"""
    envs = {}
    index = 0
    exported = False
    while index < len(seg):
        token = seg[index]
        if token in WRAPPER_FLAGS:
            flags, valued = WRAPPER_FLAGS[token]
            index += 1
            while index < len(seg) and seg[index].startswith("-") and seg[index] != "-":
                if seg[index] in valued:
                    index += 2
                elif seg[index] in flags:
                    index += 1
                else:
                    break
            continue
        if token == "export":
            exported = True
            index += 1
            continue
        if ENV_ASSIGN.match(token):
            key, value = token.split("=", 1)
            envs[key] = value
            index += 1
            continue
        break
    return envs, seg[index:], exported


def git_invocation(rest):
    """rest 是去掉 env 前缀的 token；是 git 调用则返回 (全局选项, 参数)。"""
    if not rest or os.path.basename(rest[0]) != "git":
        return None
    index = 1
    globals_ = []
    while index < len(rest):
        token = rest[index]
        if token in GIT_OPTS_WITH_VALUE and index + 1 < len(rest):
            globals_ += [token, rest[index + 1]]
            index += 2
            continue
        if token.startswith("-"):
            globals_.append(token)
            index += 1
            continue
        break
    return globals_, rest[index:]


def analyze(cmd, cwd):
    """→ [(envs, exported, git 调用或 None, 该段生效 cwd)]；cd / pushd 会被跟踪。"""
    result = []
    eff = cwd
    for line in strip_heredocs(cmd).splitlines():
        segment = []
        for token in tokenize(line):
            if token in OPS or (token and set(token) <= PUNCT):
                if segment:
                    result.append(_analyze_segment(segment, eff))
                    eff = result[-1][3]
                    segment = []
            else:
                segment.append(token)
        if segment:
            result.append(_analyze_segment(segment, eff))
            eff = result[-1][3]
    return result


def _analyze_segment(seg, eff):
    envs, rest, exported = split_prefix(seg)
    if rest and rest[0] in ("cd", "pushd"):
        index = 1
        while index < len(rest) and rest[index].startswith("-") and rest[index] != "-":
            if rest[index] == "--":
                index += 1
                break
            index += 1
        if index < len(rest) and rest[index] != "-":
            eff = _join(eff, rest[index])
        return envs, exported, None, eff
    return envs, exported, git_invocation(rest), eff


def commit_has_no_verify(args):
    """args[0] == 'commit'；正确跳过带值选项（-m "-n" 不算标记）。"""
    found = False
    index = 1
    while index < len(args):
        token = args[index]
        step = 1
        if token in ("--no-verify", "-n"):
            found = True
        elif token.startswith("--"):
            if token.split("=", 1)[0] in COMMIT_OPTS_WITH_VALUE and "=" not in token:
                step = 2
        elif token.startswith("-") and token != "-":
            cluster = token[1:]
            for pos, char in enumerate(cluster):
                if char == "n":
                    found = True
                    continue
                if char in COMMIT_SHORT_WITH_VALUE:
                    if pos == len(cluster) - 1:
                        step = 2  # 值在下一个 token
                    break
        index += step
    return found


def is_whole_tree(sub, args):
    if sub == "reset":
        return "--hard" in args
    if sub == "clean":
        return any(re.match(r"^-[A-Za-z]*f", a) or a == "--force" for a in args)
    if sub == "stash":
        rest = [a for a in args[1:] if not a.startswith("-")]
        return not rest or rest[0] in ("push", "save", "clear", "drop")
    if sub in ("checkout", "switch"):
        # 建分支不覆盖工作区；-f / --discard-changes 会（实测 git checkout -f main 还原文件）
        if any(a in ("-b", "-B", "--orphan", "-c", "-C", "--create") for a in args):
            return False
        if any(a in ("-f", "--force", "--discard-changes") for a in args):
            return True
        if sub == "switch":
            return False
        return any(
            a in WHOLE_TREE_PATHSPECS or a.endswith("/*")
            for a in args
            if not a.startswith("-")
        )
    if sub == "restore":
        return any(
            a in WHOLE_TREE_PATHSPECS or a.endswith("/*")
            for a in args
            if not a.startswith("-")
        )
    return False


def check_bash(cmd, cwd, me):
    segments = analyze(cmd, cwd)
    exported = {}
    for envs, is_export, git_call, eff in segments:
        envs_here = dict(exported)
        envs_here.update(envs)
        if is_export:
            exported.update(envs)   # export 对后续段生效；普通前缀只作用于本段
        if envs_here.get("DEPLOY_IN_WORKTREE") == "1":
            deny(
                "DEPLOY_IN_WORKTREE=1 是隔离壳内层专用，外部预设会绕开三道闸",
                [
                    "绕开的闸：部署锁（串行=防 OOM）/ 隔离树（部署只读 origin，不读本地工作区）",
                    "          / 单调前进闸（8/8 防倒退）",
                    "正常部署：./scripts/deploy.sh -l|-w|-a（隔离默认开启，无需设这个变量）",
                ],
            )
        if not git_call:
            continue
        globals_, args = git_call
        if not args:
            continue
        if "--help" in args or (len(args) > 1 and args[1] == "-h"):
            continue  # 只读帮助
        sub = args[0]
        git_env = {
            "GIT_DIR": envs_here.get("GIT_DIR"),
            "GIT_WORK_TREE": envs_here.get("GIT_WORK_TREE"),
        }
        if sub == "commit":
            if commit_has_no_verify(args) and envs_here.get("SL_ALLOW_NO_VERIFY") != "1":
                deny(
                    "git commit --no-verify 会跳过 pre-commit（含 .local 链）",
                    [
                        "被跳过的守卫：hub 提交拦截 / macOS 元数据文件检查",
                        "确实要绕过（WIP 存档等）：SL_ALLOW_NO_VERIFY=1 git commit …",
                    ],
                )
            if is_hub_of(repo_of(globals_, eff, git_env), me) and envs_here.get("SL_ALLOW_HUB_COMMIT") != "1":
                deny(
                    "在主 checkout（hub）里 git commit",
                    [
                        "hub 只作只读镜像（持分支 / node_modules / env），提交一律在会话 worktree",
                        "",
                        "  ./scripts/session-wt.sh start <name>",
                        "  cd /tmp/wt-<name> && git add -- <你的路径…> && git commit -m …",
                        "改动已经在 hub 工作区里（归属你的那部分）：",
                        "  ./scripts/session-wt.sh adopt <name> -- <你的路径…>",
                        "一次性收口场景：SL_ALLOW_HUB_COMMIT=1 git commit …",
                    ],
                )
        elif sub == "push":
            no_verify = "--no-verify" in args   # push 的 -n 是 --dry-run，不能复用 commit 解析
            skip_env = envs_here.get("SKIP_PREPUSH_CHECK") == "1"
            if (no_verify or skip_env) and envs_here.get("SL_ALLOW_NO_VERIFY") != "1" \
                    and envs_here.get("SL_ALLOW_SKIP_PREPUSH") != "1":
                deny(
                    "会跳过 pre-push（落后 / 非快进 / 删保护分支）",
                    [
                        "命中：%s" % ("--no-verify" if no_verify else "SKIP_PREPUSH_CHECK=1"),
                        "落后就 rebase 后再推：./scripts/session-wt.sh push <name>",
                        "确实要绕过（恢复等）：SL_ALLOW_NO_VERIFY=1 / SL_ALLOW_SKIP_PREPUSH=1",
                    ],
                )
        elif sub in DESTRUCTIVE and is_whole_tree(sub, args):
            if is_hub_of(repo_of(globals_, eff, git_env), me) and envs_here.get("SL_ALLOW_HUB_DESTRUCTIVE") != "1":
                deny(
                    "hub 里整树覆盖型 git（%s）会抹掉其他会话的在制品" % sub,
                    [
                        "命令: git %s" % " ".join(args),
                        "hub 工作区是所有会话共享的现场：只在自己的 worktree 里做整树操作",
                        "查状态可用：git -C <hub> status（只读）",
                        "确实要执行：SL_ALLOW_HUB_DESTRUCTIVE=1 git %s" % " ".join(args),
                    ],
                )


def main():
    if os.environ.get("SL_GUARD_BYPASS") == "1":
        return 0
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # 输入异常不卡工具调用
    if not isinstance(payload, dict):
        return 0
    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    cwd = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()

    if not sevenlocks_active(cwd):
        return 0  # 不是 SevenLocks 仓库（含 submodule / 别的项目）：本层不介入
    me = repo_of([], cwd)
    if tool in TOOL_PATH_KEY:
        if me:
            check_path_tool(tool, tool_input, cwd, me)
    elif tool == "Bash":
        command = tool_input.get("command")
        if isinstance(command, str) and command.strip():
            check_bash(command, cwd, me)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # fail-open：守门层自身故障不阻断开发
        note("内部异常，已放行：%r" % (exc,))
        sys.exit(0)
