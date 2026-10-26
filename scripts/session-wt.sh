#!/bin/bash
# sevenlocks-v1.18 · session-wt.sh —— 会话 worktree 生命周期管理（L1 编辑层通用件）
# 上游真源：上游项目 scripts/session-wt.sh ——通用逻辑升级照 diff 同步到上游，勿在本副本魔改。
#
# 动机：并行 AI 会话共用主 checkout 的工作区/index 是多起事故的根源（同文件覆盖 /
# 暂存区裹挟 / git restore 抹掉在制品）；worktree 让「我的提交只含我的文件」成为
# 结构性保证，分叉从混合积压变成各会话的短命分支。
#
# 用法：
#   ./scripts/session-wt.sh start <name> [base]    # 建 <WT_ROOT>/wt-<name> + 分支 wt/<name>
#                                                  #（默认基于 origin/<DEV_BRANCH>）
#   ./scripts/session-wt.sh list                    # 列出全部会话 worktree（ahead/dirty）
#   ./scripts/session-wt.sh push <name> [branch]    # fetch + rebase origin/<branch> + 推整条分支
#   ./scripts/session-wt.sh adopt <name> -- <path>…  # 把主 checkout 指定 paths 的改动复制进
#                                                  #  worktree（主 checkout 不删；归属不明时的安全出口）
#   ./scripts/session-wt.sh clean <name> [--force]  # 清理（有未推/脏改动拒绝；--force 强清）
#   ./scripts/session-wt.sh prune [--yes]           # 清理「已吸收+无活树+够老」的分支（默认 dry-run）
#   ./scripts/session-wt.sh gc-dirs [--yes]         # 清理非 worktree 的临时残留目录（无 .git；默认 dry-run）
#   ./scripts/session-wt.sh replicate               # backup/archive 分支推远端 refs/backup/*（抗机器丢失）
#   ./scripts/session-wt.sh audit                   # 只读体检：hub 脏/落后、残留目录、备份副本、中断部署
#   ./scripts/session-wt.sh conflicts <name>          # 跨会话冲突雷达：我的改动集与其他会话/hub 求交集
#
# start 顺带：hub 保鲜（ff-only，带 HEAD 守卫）、>3 天 worktree 审计、孤儿分支安全回收
# （worktree 目录已失且内容已被上游吸收的 wt/ 分支自动删；未吸收只提醒）。
# name 限 [a-zA-Z0-9._-]、不以 . 开头、不含 ..。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 主仓根：从 git-common-dir 反解（在主仓与任意 worktree 内调用都能得到主仓）
if ! _main_git=$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    echo "ERROR: $SCRIPT_DIR 不在 git 仓库内——请在仓库内调用本脚本"; exit 1
fi
MAIN_ROOT="$(cd "${_main_git}/.." && pwd)"
_MAIN_COMMON="$_main_git"

# ===== 参数层（每项目改这里；勿改下方通用逻辑）=====
SL_DEV_BRANCH="kewang"          # 开发集成分支（会话分支的基准；hub 保鲜守卫也看它）
SL_MIRROR_BRANCH="main"         # 生产镜像分支：push DEV_BRANCH 成功后自动 FF 同步；
                                #   无镜像拓扑置 ""（跳过同步与拒推守卫）
SL_NOTICE_FILE="/tmp/myproject-session-notice.txt"  # 会话公告（首行 until=YYYYMMDD 自过期）
SL_WT_ROOT="${SL_WT_ROOT:-/tmp}"  # worktree 根（可用同名环境变量覆盖，便于测试/多项目）。macOS /tmp=定期清理（3 天未访问清成空壳，
                                # 非"重启自清"）——已提交内容由孤儿回收兜、未提交文件会被抹，
                                # 在制品须及时 commit；载体判定以「目录在且有 .git」为准
# 接线（血肉示例，按项目删改）：主仓重资产软链进新 worktree——没有重资产就清空数组
SL_WIRE_DIRS=("web/node_modules" "service/.venv")
SL_COPY_FILES=("web/.env.local" "service/.env.local")
# dirty 计数忽略正则：必须与上面接线产物一一对应（精确整行匹配，防误排除真实脏文件）
SL_DIRTY_IGNORE='^\?\? (web/)?node_modules(/|$)|^\?\? service/\.venv(/|$)|^\?\? web/\.env\.local$|^\?\? service/\.env\.local$'
SL_KEEP_BRANCHES='^(kewang|main)$|^(backup|archive)(/|$)'
SL_PRUNE_AGE_DAYS=3                                   # 分支最后提交 ≥N 天才清理
SL_HISTORY_LOG="/tmp/myproject-deploy-history.log"        # 部署历史（中断检测；与 deploy.sh 同路径）
SL_BACKUP_CHECK_TTL=3600                              # 备份远端副本检查缓存秒数（ls-remote 可达 12s）
SL_BACKUP_CHECK_STAMP="${TMPDIR:-/tmp}/myproject-backup-check.stamp"  # 多项目同机时按项目改

# ===================================================

WT_ROOT="$SL_WT_ROOT"

print_session_notice() {
    [ -f "$SL_NOTICE_FILE" ] || return 0
    local _until
    _until=$(sed -n 's/^until=//p' "$SL_NOTICE_FILE" 2>/dev/null | head -1)
    if [ -n "$_until" ] && [ "$(date +%Y%m%d)" -gt "$_until" ]; then return 0; fi
    echo "📢 ── 会话公告 ──"
    grep -v '^until=' "$SL_NOTICE_FILE" | sed 's/^/   /'
    echo "   ─────────────"
    return 0
}

validate_name() {
    case "$1" in
        ''|.*|*..*|*/*) echo "ERROR: 非法 name '$1'（限 [a-zA-Z0-9._-]、不以 . 开头、不含 .. 或 /）"; exit 1 ;;
        *[!a-zA-Z0-9._-]*) echo "ERROR: 非法 name '$1'（限 [a-zA-Z0-9._-]）"; exit 1 ;;
    esac
}

# 物理路径归一（macOS /tmp -> /private/tmp；worktree list 输出的是后者）。
# 不做归一，注册判据 grep 恒不命中，安全护栏等于不存在（2026-10-22 审查实测）。
_realpath() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }

# mtime 秒：GNU 优先（`stat -f` 在 GNU 上是文件系统报告，会污染算术），macOS 回退。
_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0; }

# 卫生体检（2026-10-22）：把「审计原本看不见的地方」纳入——hub 直编、非 git 临时目录、
# 无远端副本的备份、被中断的部署。全部只读；清理分别走 prune / gc-dirs / replicate。
_audit_hygiene() {
    local reg d kb
    reg=$(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's|^worktree ||p' | while IFS= read -r w; do _realpath "$w"; done)
    local hd
    hd=$(git -C "$MAIN_ROOT" status --porcelain --untracked-files=no 2>/dev/null | grep -c . || true)
    if [ "${hd:-0}" -gt 0 ]; then
        echo "审计: 🚨 主 checkout 有 ${hd} 个已跟踪脏文件——hub 只作只读镜像；提交已被 pre-commit 守卫拒绝"
    fi
    # 非 worktree 临时目录：git worktree prune 与分支回收都看不见（2026-10-22 实测 17 个/115MB）
    local residue=0 residue_kb=0
    for d in "$WT_ROOT"/wt-*; do
        [ -d "$d" ] || continue
        printf '%s\n' "$reg" | grep -qxF -- "$(_realpath "$d")" && continue
        [ -e "$d/.git" ] && continue
        residue=$((residue + 1))
        kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}' || true)
        residue_kb=$((residue_kb + ${kb:-0}))
    done
    if [ "$residue" -gt 0 ]; then
        echo "审计: ${residue} 个非 worktree 临时目录（$((residue_kb / 1024))MB）——session-wt gc-dirs 查看/清理"
    fi
    # 备份远端副本：必须比 SHA（只比 ref 存在会把「远端是旧快照」误报成有备份）。
    # ls-remote 实测可达 12s，用 stamp 缓存 SL_BACKUP_CHECK_TTL 秒；失败不写 stamp（下轮重试）。
    local local_backups remote_backups missing=0 stale=0 b sha rsha
    local stamp="${SL_BACKUP_CHECK_STAMP:-${TMPDIR:-/tmp}/myproject-backup-check.stamp}" ttl="${SL_BACKUP_CHECK_TTL:-3600}" _sage=999999999
    local_backups=$(git -C "$MAIN_ROOT" for-each-ref --format='%(refname)' 'refs/heads/backup/' 'refs/heads/archive/' 2>/dev/null || true)
    if [ -f "$stamp" ]; then _sage=$(( $(date +%s) - $(_mtime "$stamp") )); fi
    if [ -n "$local_backups" ] && [ "$_sage" -ge "$ttl" ]; then
        if remote_backups=$(git -C "$MAIN_ROOT" ls-remote origin 'refs/backup/*' 2>/dev/null); then
            for b in $local_backups; do
                b="${b#refs/heads/}"
                sha=$(git -C "$MAIN_ROOT" rev-parse "$b" 2>/dev/null || true)
                rsha=$(printf '%s\n' "$remote_backups" | awk -v r="refs/backup/$b" '$2 == r {print $1; exit}')
                if [ -z "$rsha" ]; then missing=$((missing + 1))
                elif [ "$rsha" != "$sha" ]; then stale=$((stale + 1)); fi
            done
            if [ "$missing" -gt 0 ] || [ "$stale" -gt 0 ]; then
                echo "审计: backup/archive 分支 ${missing} 个无远端副本、${stale} 个远端已过期（session-wt replicate）"
            fi
            touch "$stamp" 2>/dev/null || true
        fi
    fi
    # 被中断的部署（START 无 END）：只报，不清理
    if [ -x "$SCRIPT_DIR/deploy_watchdog.sh" ]; then
        local wd
        wd=$(SL_HISTORY_LOG="$SL_HISTORY_LOG" "$SCRIPT_DIR/deploy_watchdog.sh" --quiet 2>&1 || true)
        [ -n "$wd" ] && printf '%s\n' "$wd" | sed 's/^/审计: /'
    fi
    return 0
}

cmd_start() {
    print_session_notice
    local name="$1" base="${2:-origin/$SL_DEV_BRANCH}"
    validate_name "$name"
    local wt="$WT_ROOT/wt-$name" br="wt/$name"
    if [ -e "$wt" ] && [ ! -e "$wt/.git" ]; then
        # 空壳只有**空目录**才自动清；非空可能是别的会话/项目在制品，绝不 rm -rf
        if [ -z "$(ls -A "$wt" 2>/dev/null)" ]; then
            echo "清理: ${wt} 为 /tmp 清理残留的空壳（空目录），已移除"
            rm -rf "$wt"
        else
            echo "ERROR: ${wt} 存在、不是活 worktree、但目录非空——拒绝自动删除"
            echo "       确认无用后手动处理：rm -rf ${wt}（或 session-wt gc-dirs 查看）"
            exit 1
        fi
    fi
    if [ -e "$wt" ]; then echo "ERROR: $wt 已存在（重名或残留；clean 后重试）"; exit 1; fi
    git -C "$MAIN_ROOT" fetch origin "$SL_DEV_BRANCH" ${SL_MIRROR_BRANCH:+"$SL_MIRROR_BRANCH"} --quiet \
        || echo "WARN: fetch 失败，base 用本地引用 $base"
    # hub 保鲜：主仓是所有会话检索基底——start 顺带 ff-only 快进。仅在主仓 HEAD 恰为
    # DEV_BRANCH 时执行（无守卫时主仓停在别的分支会被静默快进并重写工作区）；
    # 分叉未收口/在制品挡路时 ff-only 自动失败 → 跳过，零风险。
    if [ "$(git -C "$MAIN_ROOT" symbolic-ref -q --short HEAD 2>/dev/null || true)" = "$SL_DEV_BRANCH" ]; then
        if git -C "$MAIN_ROOT" merge --ff-only "origin/$SL_DEV_BRANCH" >/dev/null 2>&1; then
            echo "hub: 主仓 ${SL_DEV_BRANCH} 已保鲜到 origin/${SL_DEV_BRANCH}"
        else
            _hb=$(git -C "$MAIN_ROOT" rev-list --count "HEAD..origin/$SL_DEV_BRANCH" 2>/dev/null || echo 0)
            _ha=$(git -C "$MAIN_ROOT" rev-list --count "origin/$SL_DEV_BRANCH..HEAD" 2>/dev/null || echo 0)
            if [ "${_hb:-0}" -gt 0 ]; then
                # 静默跳过是事故温床：主仓落后时会话会据此读旧文件、按旧 ref 采基线
                echo "hub: 🚨 主仓落后 origin/${SL_DEV_BRANCH} ${_hb} 个提交（领先 ${_ha}）——本次未快进"
                echo "hub: 🚨 **不要把主仓当检索/改动基底**：只在本 worktree（基于 origin/${SL_DEV_BRANCH}）里读和改"
                echo "hub: 🚨 要让主仓跟上：先处理在制品/分叉，再 pull --rebase"
            else
                echo "hub: 主仓未能 ff 快进（在制品挡路/主仓被占用）——跳过（本地无落后提交）"
            fi
        fi
    else
        echo "hub: 主仓 HEAD 不在 ${SL_DEV_BRANCH}——保鲜跳过（收口/打 tag 后请切回）"
    fi
    # 本地镜像分支保鲜：origin/<镜像> 由推送工具自动 FF 跟随开发分支，但本地镜像分支没人更新
    # 会停在旧提交（上游项目曾停 9-08 一个半月）。四条同时满足才动：配置了镜像 + 分支存在 +
    # 未被任何 worktree 检出 + 是 origin 祖先（纯快进）+ 确实落后。失败静默跳过。
    if [ -n "$SL_MIRROR_BRANCH" ] && git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$SL_MIRROR_BRANCH" \
        && ! git -C "$MAIN_ROOT" worktree list --porcelain | grep -q "^branch refs/heads/$SL_MIRROR_BRANCH$" \
        && git -C "$MAIN_ROOT" merge-base --is-ancestor "$SL_MIRROR_BRANCH" "origin/$SL_MIRROR_BRANCH" 2>/dev/null \
        && [ "$(git -C "$MAIN_ROOT" rev-parse "$SL_MIRROR_BRANCH")" != "$(git -C "$MAIN_ROOT" rev-parse "origin/$SL_MIRROR_BRANCH")" ]; then
        if git -C "$MAIN_ROOT" fetch origin "$SL_MIRROR_BRANCH:$SL_MIRROR_BRANCH" --quiet 2>/dev/null; then
            echo "$SL_MIRROR_BRANCH: 本地 $SL_MIRROR_BRANCH 已快进到 origin/$SL_MIRROR_BRANCH ($(git -C "$MAIN_ROOT" rev-parse --short "$SL_MIRROR_BRANCH"))"
        fi
    fi
    # 仓库 git 钩子自检：钩子是复制进 hooks 目录的（软链会在 worktree 删除后变断链），
    # 源脚本改了不会自动生效。只在缺失/陈旧时提示，不阻断 start。
    if [ -x "$SCRIPT_DIR/install-git-hooks.sh" ]; then
        if ! "$SCRIPT_DIR/install-git-hooks.sh" --check >/dev/null 2>&1; then
            echo "提醒: 仓库 git 钩子（pre-commit hub 守卫 / pre-push）缺失或与仓库版本不同——建议跑 $SCRIPT_DIR/install-git-hooks.sh"
        fi
    fi
    # worktree 审计：超 3 天未动的可能是泄漏（年龄取 max(分支最后提交时间, 目录 mtime)，
    # 减「满 3 天的长会话被误报未动」的误报）
    _stale=0
    for _w in $(git -C "$MAIN_ROOT" worktree list --porcelain | sed -n 's/^worktree //p'); do
        [ "$_w" = "$MAIN_ROOT" ] && continue
        [ -d "$_w" ] || continue
        _dir_ts=$(_mtime "$_w")
        _cmt_ts=$(git -C "$_w" log -1 --format=%ct 2>/dev/null || echo 0)
        [ "$_cmt_ts" -gt "$_dir_ts" ] 2>/dev/null && _dir_ts="$_cmt_ts"
        _age=$(( ( $(date +%s) - _dir_ts ) / 86400 ))
        [ "$_age" -ge 3 ] 2>/dev/null && _stale=$((_stale + 1))
    done
    [ "$_stale" -gt 0 ] && echo "审计: ${_stale} 个 worktree 超 3 天未动（git worktree list 查看，确认无人用后清理）"
    _prune_n=$(_prune_candidates 2>/dev/null | grep -c . || true)
    [ "$_prune_n" -gt 0 ] && echo "审计: ${_prune_n} 个已吸收分支可清理（session-wt prune 查看）"
    # 卫生体检（2026-10-22）：hub 直编 / 非 git 残留 / 备份副本 / 中断部署
    _audit_hygiene
    # 孤儿分支安全回收：worktree 载体已失（macOS /tmp 定期清理/重启/手删）且内容已被
    # origin 吸收（cherry patch-id 无 '+'，rebase 推送后的等价提交也算）的 wt/ 分支自动删
    # ——在制品载体已失且内容已在远端，删除无损。未吸收的孤儿只提醒不删（可能藏着
    # 未推工作，「不碰别人的半成品」）。先 prune 清失效注册，否则 branch -D 被 git 拒。
    git -C "$MAIN_ROOT" worktree prune 2>/dev/null || true
    _recycled=0
    for _obr in $(git -C "$MAIN_ROOT" for-each-ref --format='%(refname:short)' 'refs/heads/wt/'); do
        _oname=${_obr#wt/}
        # 载体存活判定=目录在**且**还是活 worktree（有 .git）——macOS /tmp 会把闲置树清成
        # 空壳（目录在、内容 0 文件、.git 没了）：壳=在制品载体已失，视同目录不存在处理
        if [ -d "$WT_ROOT/wt-$_oname" ] && [ -e "$WT_ROOT/wt-$_oname/.git" ]; then continue; fi
        _unabsorbed=$(_cherry_unabsorbed "$_obr")
        if [ "$_unabsorbed" = "CHERRY_FAILED" ]; then
            echo "提醒: 孤儿分支 ${_obr} 吸收状态判定失败（origin/${SL_DEV_BRANCH} 引用缺失？）——保守跳过，人工核查: git cherry origin/${SL_DEV_BRANCH} ${_obr}"
            continue
        fi
        if [ "$_unabsorbed" -eq 0 ]; then
            if git -C "$MAIN_ROOT" branch -D "$_obr" >/dev/null 2>&1; then
                echo "回收: 孤儿分支 ${_obr}（worktree 已失，内容已被 origin/${SL_DEV_BRANCH} 吸收）"
                _recycled=$((_recycled + 1))
            fi
        else
            echo "提醒: 孤儿分支 ${_obr} 有 ${_unabsorbed} 个未吸收提交（worktree 目录已不在）——取回: session-wt start ${_oname}；确认丢弃: git branch -D ${_obr}"
        fi
    done
    # 分支已存在=未吸收孤儿的「取回」路径（原载体已被 /tmp 清成空壳）——不带 -b 挂回
    # （审查 P1-1：add -b 对已存在分支 fatal，取回指引三重堵死）
    if git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$br"; then
        git -C "$MAIN_ROOT" worktree add "$wt" "$br" --quiet
    else
        git -C "$MAIN_ROOT" worktree add -b "$br" "$wt" "$base" --quiet
    fi
    # 接线：软链/拷贝主仓重资产（参数层 SL_WIRE_DIRS / SL_COPY_FILES 定义）
    if [ "${#SL_WIRE_DIRS[@]}" -gt 0 ]; then
        for _p in "${SL_WIRE_DIRS[@]}"; do
            [ -n "$_p" ] || continue
            if [ -d "$MAIN_ROOT/$_p" ] && [ ! -e "$wt/$_p" ]; then
                mkdir -p "$(dirname "$wt/$_p")"
                ln -s "$MAIN_ROOT/$_p" "$wt/$_p"
            fi
        done
    fi
    if [ "${#SL_COPY_FILES[@]}" -gt 0 ]; then
        for _p in "${SL_COPY_FILES[@]}"; do
            [ -n "$_p" ] || continue
            if [ -f "$MAIN_ROOT/$_p" ] && [ ! -e "$wt/$_p" ]; then
                mkdir -p "$(dirname "$wt/$_p")"
                cp "$MAIN_ROOT/$_p" "$wt/$_p"
            fi
        done
    fi
    echo "OK: worktree=${wt} 分支=${br}（基于 ${base}；接线按参数层完成）"
    echo "下一步：此后命令一律 cd ${wt} && …（若你的 shell 每次调用重置 cwd）"
}

cmd_adopt() {
    # ⚠️ bash 3.2：local 同行引用前序变量会 unbound，逐条声明
    local name="$1"
    validate_name "$name"
    shift
    if [ "${1:-}" = "--" ]; then shift; fi
    if [ $# -lt 1 ]; then
        echo "ERROR: 需要至少一个路径（相对仓库根）——例：session-wt adopt ${name} -- app/engine/rules.py"
        return 1
    fi
    local p
    for p in "$@"; do
        case "$p" in
            ''|/*|.|./|..|../*|*/..|*/../*|:*)
                echo "ERROR: 非法路径 '$p'（限仓库内相对文件/目录；不接受 . / .. / pathspec magic）" >&2; return 1 ;;
        esac
        case "/$p/" in *"/../"*) echo "ERROR: 非法路径 '$p'（含 ..）" >&2; return 1 ;; esac
    done
    local wt="$WT_ROOT/wt-$name"
    if [ ! -d "$wt" ]; then
        local sout
        if ! sout=$(cmd_start "$name" 2>&1); then
            printf '%s\n' "$sout"
            echo "ERROR: 建 worktree ${wt} 失败" >&2
            return 1
        fi
    fi
    _assert_wt_owned "$wt" "wt/$name" || return 1
    if [ ! -d "$wt" ]; then echo "ERROR: worktree ${wt} 不存在（创建未生效）" >&2; return 1; fi
    # 重命名：自动把旧路径纳入 diff——只传新路径会留下旧文件；只传旧路径会丢新内容
    local allpaths=("$@") r_old r_new
    while IFS=$'\t' read -r r_old r_new; do
        [ -n "${r_old:-}" ] || continue
        for p in "$@"; do
            case "$r_new" in
                "$p"|"$p"/*) allpaths+=("$r_old"); break ;;
            esac
        done
    done <<EOF
$(git -C "$MAIN_ROOT" diff --name-status -M HEAD 2>/dev/null | awk -F'\t' '$1 ~ /^R/ {print $2"\t"$3}')
EOF
    # ① 已跟踪路径：相对 HEAD 的完整 diff（含暂存区），二进制安全
    local patch copied=0 failed=0 faillist="" ufile
    # 全局承接：EXIT trap 在函数返回后触发，local 变量那时已出作用域（set -u → unbound，
    # 退出码被改成 1，调用方会把「成功」当失败；2026-10-24 实测复现）
    SL_ADOPT_PATCH=$(mktemp "${TMPDIR:-/tmp}/adopt.XXXXXX") || return 1
    patch="$SL_ADOPT_PATCH"
    trap 'rm -f "$SL_ADOPT_PATCH"' EXIT
    if ! git -C "$MAIN_ROOT" diff HEAD --binary -- "${allpaths[@]}" > "$patch" 2>/dev/null; then
        echo "ERROR: 读取主 checkout diff 失败（路径是否存在？）" >&2
        return 1
    fi
    if [ -s "$patch" ] && git -C "$wt" apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "提示: ${wt} 已包含这些改动（补丁可反向应用），跳过重复应用"
    elif [ -s "$patch" ]; then
        if ! git -C "$wt" apply --binary "$patch" 2>/dev/null; then
            echo "ERROR: 补丁无法应用到 ${wt}（两棵树基线不同）——worktree 已保留，可手工比对；主 checkout 未改动" >&2
            return 1
        fi
    fi
    # ② 未跟踪文件：逐文件枚举（含目录内文件），不碰 ignored（.env/node_modules 不会整包搬）
    while IFS= read -r ufile; do
        [ -n "$ufile" ] || continue
        if ! mkdir -p "$wt/$(dirname "$ufile")" 2>/dev/null; then
            failed=$((failed + 1)); faillist="${faillist}  ${ufile}（建目录失败）
"
            continue
        fi
        if cp -p "$MAIN_ROOT/$ufile" "$wt/$ufile" 2>/dev/null; then
            copied=$((copied + 1))
        else
            failed=$((failed + 1)); faillist="${faillist}  ${ufile}（复制失败）
"
        fi
    done <<EOF
$(git -C "$MAIN_ROOT" ls-files --others --exclude-standard -- "$@" 2>/dev/null)
EOF
    local changed
    changed=$(git -C "$wt" status --porcelain 2>/dev/null | grep -c . || true)
    if [ "${changed:-0}" -eq 0 ]; then
        echo "ERROR: 指定路径没有产生任何改动或新文件（路径写错？）——主 checkout 未动" >&2
        return 1
    fi
    echo "OK: 已复制到 ${wt}（未跟踪文件 ${copied} 个；worktree 现有 ${changed} 个变更）"
    if [ "$failed" -gt 0 ]; then
        printf "复制失败 ${failed} 个：\n%s" "$faillist" >&2
        return 1
    fi
    echo "    主 checkout 原样保留（本命令不删除任何文件）；其他会话的改动不要动"
    echo "下一步：cd ${wt} && git diff --stat && git add -- <path>… && git commit -m … && session-wt push ${name}"
}

_assert_wt_owned() {
    local wt="$1" br="$2" common cur
    common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    if [ -z "$common" ] || [ "$common" != "$_MAIN_COMMON" ]; then
        echo "ERROR: ${wt} 不是本仓库的 worktree（common-dir=${common:-无}）——拒绝操作；换一个 name" >&2
        return 1
    fi
    cur=$(git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null || true)
    if [ "$cur" != "$br" ]; then
        echo "ERROR: ${wt} 检出的不是 ${br}（当前=${cur:-detached}）——拒绝操作；换一个 name" >&2
        return 1
    fi
    return 0
}

# dirty 计数：排除接线产物（未进 gitignore 时以 ?? 形态出现）——精确整行匹配，
# 无锚定子串过滤会把 .bak 等真实脏文件误排除、clean 非 force 也无警告删真实文件
wt_dirty_count() {
    if [ -n "$SL_DIRTY_IGNORE" ]; then
        git -C "$1" status --porcelain 2>/dev/null | grep -vE "$SL_DIRTY_IGNORE" | grep -c . || true
    else
        git -C "$1" status --porcelain 2>/dev/null | grep -c . || true
    fi
}

# cherry 未吸收计数（patch-id 判定）。git cherry 失败（origin 引用缺失等）输出
# CHERRY_FAILED——调用方必须保守跳过删除，不能把「判不了」当「已吸收=0」而删分支。
_cherry_unabsorbed() {
    local out
    out=$(git -C "$MAIN_ROOT" cherry "origin/$SL_DEV_BRANCH" "$1" 2>/dev/null) || { echo "CHERRY_FAILED"; return 0; }
    printf '%s\n' "$out" | grep -c '^+' || true
}

cmd_list() {
    print_session_notice
    local d name br ahead dirty
    for d in "$WT_ROOT"/wt-*; do
        [ -d "$d" ] || continue
        name="${d##*/wt-}"
        br="wt/$name"
        # 外来/创建中的目录：不是 git worktree 就标注跳过，不让整个列表挂掉
        if ! git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
            echo "${name}  (非 git worktree：创建中或外来目录)  ${d}"
            continue
        fi
        if git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$br"; then
            ahead=$(git -C "$MAIN_ROOT" rev-list --count "origin/$SL_DEV_BRANCH..$br" 2>/dev/null || echo '?')
        else
            ahead='(非wt分支)'
        fi
        dirty=$(wt_dirty_count "$d")
        echo "${name}  ahead=${ahead}  dirty=${dirty}  ${d}"
    done
}

cmd_push() {
    # ⚠️ local 参数先整体展开再赋值（bash 3.2）：引用同行前序变量必须分行声明
    local name="$1"
    validate_name "$name"
    local target="${2:-$SL_DEV_BRANCH}"
    if [ -n "$SL_MIRROR_BRANCH" ] && [ "$target" = "$SL_MIRROR_BRANCH" ]; then
        echo "ERROR: 目标 ${SL_MIRROR_BRANCH}=生产镜像分支——个人提交不应直推；推 ${SL_DEV_BRANCH}，镜像由本工具自动 FF 同步"
        exit 1
    fi
    local wt="$WT_ROOT/wt-$name"
    local br="wt/$name"
    [ -d "$wt" ] || { echo "ERROR: 无 ${wt}（先 start）"; exit 1; }
    _assert_wt_owned "$wt" "$br" || exit 1
    git -C "$MAIN_ROOT" fetch origin "$target" --quiet || { echo "ERROR: fetch origin/${target} 失败"; exit 1; }
    # 未提交改动先拦：否则 push 报「无领先提交」假成功（agent 会以为已推送，部署仍是旧代码）
    local dirty
    dirty=$(wt_dirty_count "$wt")
    if [ "$dirty" -gt 0 ]; then
        echo "ERROR: ${wt} 有 ${dirty} 个未提交改动——先 git add -- <paths> && git commit 再 push"
        git -C "$wt" status --porcelain 2>/dev/null | head -10 | sed 's/^/  /'
        exit 1
    fi
    local n
    n=$(git -C "$wt" rev-list --count "origin/$target..$br")
    if [ "$n" = "0" ]; then echo "OK: 无领先 origin/${target} 的提交，无需推送"; exit 0; fi
    echo "推送 $n 个提交（先 rebase 到 origin/${target}）..."
    if ! git -C "$wt" rebase "origin/$target"; then
        echo "ERROR: rebase 冲突——cd $wt 解冲突后 git rebase --continue，再重跑本命令"
        exit 1
    fi
    if ! git -C "$wt" push origin "HEAD:refs/heads/$target"; then
        echo "ERROR: push 被拒（rebase 期间 origin/${target} 又前进）——重跑本命令即可"
        exit 1
    fi
    echo "OK: 已推 $n 个提交到 origin/${target}（CI 已触发；合并前建议已自测）"
    # 镜像自动同步：DEV_BRANCH 推送成功后顺手 FF 镜像分支——远端默认分支滞后=新克隆
    # 拿旧代码，靠人记着同步必腐化。非 FF（镜像出现独有提交）天然被拒只提醒不强推；
    # 失败不阻塞推送主流程。⚠️ 配套：镜像分支必须从 CI 的 push 触发分支里移除（重复 run）。
    if [ -n "$SL_MIRROR_BRANCH" ] && [ "$target" = "$SL_DEV_BRANCH" ]; then
        if git -C "$wt" push origin "HEAD:refs/heads/$SL_MIRROR_BRANCH"; then
            echo "镜像: ${SL_MIRROR_BRANCH} 已 FF 同步到 $(git -C "$wt" rev-parse --short HEAD)"
        else
            echo "WARN: ${SL_MIRROR_BRANCH} 镜像 FF 同步未成（非 FF=镜像有独有提交？网络？）——确认后手动 git push origin origin/${SL_DEV_BRANCH}:${SL_MIRROR_BRANCH}"
        fi
    fi
}

# 清理「已吸收 + 无活树 + 够老 + 非保留」的本地分支（默认 dry-run；--yes 执行）
# 判据与孤儿回收同源：cherry 无 '+'（patch-id，rebase 吸收也算）+ 无 worktree + 够老；
# SL_KEEP_BRANCHES 内永不触碰（CHERRY_FAILED 也跳过）。ad-hoc 命名的会话分支靠它收敛。
# 候选分支（stdout 每行 "name<TAB>age"）：删除判据的单一真源——start 审计与 prune 共用，
# 避免两处逻辑漂移（2026-10-22 审查 P2-4/P3-1：曾因极性不同在非法参数下一处 fail-closed、
# 一处 fail-open）。判据：非开发分支 + 非保留 + 未被任何 worktree 占用（一次 porcelain 解析，
# 覆盖路径含空格/locked/目录已删）+ cherry 无未吸收（patch-id）+ 最后提交 ≥ 年龄阈值。
_prune_candidates() {
    case "$SL_PRUNE_AGE_DAYS" in
        ''|*[!0-9]*) echo "ERROR: SL_PRUNE_AGE_DAYS 必须是非负整数（当前 '${SL_PRUNE_AGE_DAYS}'）" >&2; return 1 ;;
    esac
    printf 'x\n' | grep -qE "$SL_KEEP_BRANCHES" >/dev/null 2>&1
    case $? in 0|1) : ;; *) echo "ERROR: SL_KEEP_BRANCHES 不是合法正则" >&2; return 1 ;; esac
    local occupied b u ts age
    occupied=$(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's|^branch refs/heads/||p')
    for b in $(git -C "$MAIN_ROOT" for-each-ref --format='%(refname:short)' refs/heads/); do
        [ "$b" = "$SL_DEV_BRANCH" ] && continue
        case "$b" in wt/*) continue ;; esac          # wt/ 由孤儿回收负责，避免重复提示
        printf '%s' "$b" | grep -qE "$SL_KEEP_BRANCHES" && continue
        printf '%s\n' "$occupied" | grep -qxF -- "$b" && continue
        u=$(_cherry_unabsorbed "$b")
        [ "$u" = "CHERRY_FAILED" ] && continue
        [ "$u" != "0" ] && continue
        ts=$(git -C "$MAIN_ROOT" log -1 --format=%ct "$b" 2>/dev/null || echo 0)
        age=$(( ( $(date +%s) - ts ) / 86400 ))
        [ "$age" -ge "$SL_PRUNE_AGE_DAYS" ] || continue
        printf '%s\t%s\n' "$b" "$age"
    done
}

# 清理候选分支（默认 dry-run；--yes 执行）。删除成功/失败分别计数，失败单列并置非 0 退出
# —— 此前 `branch -D ... || true` 会把 locked 占用/含空格路径的失败算成成功（审查 P2-1 复现）。
cmd_prune() {
    local apply="${1:-}"
    git -C "$MAIN_ROOT" fetch origin "$SL_DEV_BRANCH" --quiet 2>/dev/null || true
    git -C "$MAIN_ROOT" worktree prune 2>/dev/null || true
    local cand n del=0 failed=0 list="" failed_list="" b age err
    cand=$(_prune_candidates) || return 1
    n=$(printf '%s' "$cand" | grep -c . || true)
    if [ "$n" -eq 0 ]; then
        echo "OK: 无可清理分支（判据：已吸收 + 无活树 + ≥${SL_PRUNE_AGE_DAYS} 天 + 非保留）"
        return 0
    fi
    while IFS=$'\t' read -r b age; do
        [ -n "$b" ] || continue
        list="${list}  ${b}（${age}d，已吸收）
"
        if [ "$apply" = "--yes" ]; then
            if err=$(git -C "$MAIN_ROOT" branch -D "$b" 2>&1); then
                del=$((del + 1))
            else
                failed=$((failed + 1))
                failed_list="${failed_list}  ${b}：$(printf '%s' "$err" | head -1)
"
            fi
        fi
    done <<EOF
$cand
EOF
    if [ "$apply" = "--yes" ]; then
        printf "候选 %d 个：\n%s" "$n" "$list"
        echo "已删除 ${del} 个（内容均在 origin/${SL_DEV_BRANCH}）"
        if [ "$failed" -gt 0 ]; then
            printf "删除失败 %d 个：\n%s" "$failed" "$failed_list"
            return 1
        fi
    else
        printf "可清理 %d 个分支：\n%s" "$n" "$list"
        echo "（dry-run）确认后执行：session-wt prune --yes"
    fi
}

# 清理非 worktree 的临时残留目录（2026-10-22）：/tmp 里手工复制/旧检出留下的 wt-* 目录，
# 没有 .git ⇒ git worktree prune 与分支回收都看不见（实测一次 17 个/115MB）。
# 判据（全部满足才删）：目录名 wt-* + 未被任何 worktree 注册 + 无 .git + mtime ≥ SL_PRUNE_AGE_DAYS。
# 默认 dry-run；--yes 执行。有 .git 的目录一律不碰（可能是注册异常，交给 worktree prune 排查）。
cmd_gc_dirs() {
    local apply="${1:-}"
    case "$SL_PRUNE_AGE_DAYS" in
        ''|*[!0-9]*) echo "ERROR: SL_PRUNE_AGE_DAYS 必须是非负整数（当前 '${SL_PRUNE_AGE_DAYS}'）" >&2; return 1 ;;
    esac
    case "$WT_ROOT" in
        ''|/) echo "ERROR: SL_WT_ROOT 非法（'${WT_ROOT}'）——拒绝在根目录下扫描" >&2; return 1 ;;
    esac
    local reg d ts age kb n=0 total_kb=0 del=0 failed=0 list=""
    reg=$(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's|^worktree ||p' | while IFS= read -r w; do _realpath "$w"; done)
    for d in "$WT_ROOT"/wt-*; do
        [ -d "$d" ] || continue
        printf '%s\n' "$reg" | grep -qxF -- "$(_realpath "$d")" && continue
        [ -e "$d/.git" ] && continue
        ts=$(_mtime "$d")
        age=$(( ( $(date +%s) - ts ) / 86400 ))
        [ "$age" -ge "$SL_PRUNE_AGE_DAYS" ] || continue
        kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}' || true)
        n=$((n + 1)); total_kb=$((total_kb + ${kb:-0}))
        list="${list}  ${d}（${age}d，$(( ${kb:-0} / 1024 ))MB）
"
        if [ "$apply" = "--yes" ]; then
            # TOCTOU 复核：检查与删除之间另一会话可能刚 start 出活 worktree。
            # 删除前重测「无 .git 且仍够老」——两者任一变化即放弃该候选。
            if [ -e "$d/.git" ]; then
                echo "跳过: ${d} 在检查后变成活 worktree"
                continue
            fi
            _ts2=$(_mtime "$d")
            if [ "$(( ( $(date +%s) - _ts2 ) / 86400 ))" -lt "$SL_PRUNE_AGE_DAYS" ]; then
                echo "跳过: ${d} 在检查后被写入（mtime 变新）"
                continue
            fi
            if rm -rf "$d" 2>/dev/null; then del=$((del + 1)); else failed=$((failed + 1)); fi
        fi
    done
    if [ "$n" -eq 0 ]; then
        echo "OK: 无非 worktree 残留目录（判据：wt-* + 未注册 + 无 .git + ≥${SL_PRUNE_AGE_DAYS} 天）"
        return 0
    fi
    if [ "$apply" = "--yes" ]; then
        printf "候选 %d 个（%dMB）：\n%s" "$n" "$((total_kb / 1024))" "$list"
        echo "已删除 ${del} 个（释放约 $((total_kb / 1024))MB）"
        [ "$failed" -gt 0 ] && { echo "删除失败 ${failed} 个"; return 1; }
    else
        printf "可清理 %d 个目录（%dMB）：\n%s" "$n" "$((total_kb / 1024))" "$list"
        echo "（dry-run）确认后执行：session-wt gc-dirs --yes"
    fi
    return 0
}

# 备份副本上远端（2026-10-22）：本地 backup/* 与 archive/* 此前只在单机，机器丢失即全丢。
# 推到 refs/backup/<分支名>（不进 refs/heads：不污染分支列表、不触发 CI）；1:1 映射，
# 取回命令 = git fetch origin 'refs/backup/*:refs/backup/*' && git branch <name> refs/backup/<name>。
# 幂等：远端 SHA 与本地相同即跳过。
cmd_replicate() {
    git -C "$MAIN_ROOT" fetch origin --quiet 2>/dev/null || true
    local b sha rsha pushed=0 skipped=0 failed=0 failed_list="" err
    local remote_all
    remote_all=$(git -C "$MAIN_ROOT" ls-remote origin 'refs/backup/*' 2>/dev/null || true)
    for b in $(git -C "$MAIN_ROOT" for-each-ref --format='%(refname)' 'refs/heads/backup/' 'refs/heads/archive/' 2>/dev/null || true); do
        b="${b#refs/heads/}"
        sha=$(git -C "$MAIN_ROOT" rev-parse "$b" 2>/dev/null || true)
        [ -n "$sha" ] || continue
        rsha=$(printf '%s\n' "$remote_all" | awk -v r="refs/backup/$b" '$2 == r {print $1; exit}')
        if [ "$rsha" = "$sha" ]; then skipped=$((skipped + 1)); continue; fi
        if err=$(git -C "$MAIN_ROOT" push --quiet --force origin "refs/heads/$b:refs/backup/$b" 2>&1); then
            pushed=$((pushed + 1))
            echo "已备份: ${b} → refs/backup/${b}"
        else
            failed=$((failed + 1))
            failed_list="${failed_list}  ${b}：$(printf '%s' "$err" | head -1)
"
        fi
    done
    echo "备份副本: 新推 ${pushed}，已最新 ${skipped}，失败 ${failed}"
    if [ "$failed" -gt 0 ]; then
        printf '%s' "$failed_list"
        return 1
    fi
    [ "$pushed" -gt 0 ] && echo "取回：git fetch origin 'refs/backup/*:refs/backup/*' && git branch <分支名> refs/backup/<分支名>"
    return 0
}

# 只读体检（不改任何东西）：hub 分叉/脏文件 + 卫生项。start 里也会跑卫生项。
cmd_audit() {
    print_session_notice
    local head_br behind ahead
    head_br=$(git -C "$MAIN_ROOT" symbolic-ref -q --short HEAD 2>/dev/null || echo "(detached)")
    behind=$(git -C "$MAIN_ROOT" rev-list --count "HEAD..origin/$SL_DEV_BRANCH" 2>/dev/null || echo '?')
    ahead=$(git -C "$MAIN_ROOT" rev-list --count "origin/$SL_DEV_BRANCH..HEAD" 2>/dev/null || echo '?')
    echo "hub: 分支=${head_br} 领先=${ahead} 落后=${behind}"
    [ "$behind" != "0" ] && [ "$behind" != "?" ] && echo "hub: 🚨 落后 origin/${SL_DEV_BRANCH} ${behind} 个提交——不要拿主仓当检索/改动基底"
    _audit_hygiene
}

# ── 跨会话冲突雷达（2026-10-24）─────────────────────────────────────────
# 两个会话改同一文件时，冲突原本只在 push/rebase 那一刻暴露——那时两边都已投入一整轮。
# 这里把「我的改动集」与每个其他 worktree（含 hub）的改动集提前求交集：
#   改动集 = 未提交（跟踪改动 + 未跟踪文件，排除接线产物）+ 未推送提交（origin/<dev>...HEAD）
# 只读：不改工作区、不刷新别人的 index（status 带 GIT_OPTIONAL_LOCKS=0）；唯一副作用是
# `git fetch origin` 会更新远程跟踪引用。交集只作提示，不拦任何操作。
_dirty_ignored() {
    [ -n "$SL_DIRTY_IGNORE" ] || return 1
    printf '?? %s\n' "$1" | grep -qE "$SL_DIRTY_IGNORE"
}

_changed_files() {  # $1=worktree 目录 → 每行一个路径；**返回非 0 = 有一侧读不到**
    local d="$1" rec p status_file rc=0 skipped=0
    # --no-renames：重命名拆成 D+A 两条普通记录（旧路径也要计入——另一会话可能还在改它；
    # 暂存区重命名是 `R `，只匹配 *R 会漏掉 X 位）
    status_file=$(mktemp "${SL_CONFLICTS_TMP:-${TMPDIR:-/tmp}}/status.XXXXXX") || return 1
    GIT_OPTIONAL_LOCKS=0 git -C "$d" status --porcelain -z --untracked-files=all --no-renames \
        >"$status_file" 2>/dev/null || rc=1
    while IFS= read -r -d '' rec; do
        p=${rec:3}
        case "$p" in
            *$'\n'*) skipped=$((skipped + 1)); continue ;;  # 逐行集合运算放不下换行名
        esac
        if [ "${rec:0:2}" = "??" ] && _dirty_ignored "$p"; then continue; fi
        printf '%s\n' "$p"
    done < "$status_file"
    rm -f "$status_file"
    if [ "$skipped" -gt 0 ]; then
        echo "冲突雷达: 跳过 ${skipped} 个含换行的路径" >&2
    fi
    # 未推送提交：三点 diff 取「本检出独有」的改动（detached 也适用；rebase 停住时只含
    # 已暂放/已冲突部分）。--no-renames 让重命名的旧路径也计入。
    git -C "$d" diff --name-only --no-renames "origin/$SL_DEV_BRANCH...HEAD" 2>/dev/null || rc=1
    return "$rc"
}

cmd_conflicts() {
    local name="$1"
    validate_name "$name"
    local wt="$WT_ROOT/wt-$name" mine common tmp
    [ -d "$wt" ] || { echo "ERROR: 无 ${wt}（先 start）"; exit 1; }
    # 只读命令，不要求 HEAD 恰为 wt/<name>（rebase 中 HEAD 是 detached，也要能用）
    common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    if [ "$common" != "$_MAIN_COMMON" ]; then
        echo "ERROR: ${wt} 不是本仓库的 worktree（common-dir=${common:-无}）——拒绝读取；换一个 name" >&2
        exit 1
    fi
    git -C "$MAIN_ROOT" fetch origin "$SL_DEV_BRANCH" --quiet 2>/dev/null || true
    mine=$(_realpath "$wt")
    # 全局承接临时目录：EXIT trap 在函数返回后触发，local 变量那时已出作用域（set -u 会炸）
    SL_CONFLICTS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sl-conflicts.XXXXXX") || exit 1
    tmp="$SL_CONFLICTS_TMP"
    trap 'rm -rf "$SL_CONFLICTS_TMP"' EXIT
    trap 'rm -rf "$SL_CONFLICTS_TMP"; exit 130' INT TERM

    if ! _changed_files "$wt" | LC_ALL=C sort -u > "$tmp/mine"; then
        echo "ERROR: 读不到本会话的改动集（origin/$SL_DEV_BRANCH 缺失或仓库损坏）——先 git fetch origin "$SL_DEV_BRANCH"" >&2
        exit 1
    fi
    local mine_n
    mine_n=$(grep -c . "$tmp/mine" 2>/dev/null || true)
    echo "冲突雷达：我的会话 ${name}（${mine}）"
    echo "  我的改动集：${mine_n:-0} 个文件（未提交 + 未推送提交）"

    local p label other_n hit n_hit=0 detail="" warn="" incomplete=0 base origin_hit=""
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        p=$(_realpath "$p")
        [ "$p" = "$mine" ] && continue
        if [ "$p" = "$(_realpath "$MAIN_ROOT")" ]; then
            label="hub"
        else
            case "$p" in */wt-*) label="${p##*/wt-}" ;; *) label="${p##*/}" ;; esac
        fi
        if ! _changed_files "$p" | LC_ALL=C sort -u > "$tmp/other"; then
            # 读不到 ≠ 没改动：不能当 0 文件，更不能因此打出「无重叠」
            warn="${warn}⚠️ 会话 ${label}（${p}）改动集读取失败（无共同祖先/引用缺失），未计入
"
            incomplete=1
            continue
        fi
        other_n=$(grep -c . "$tmp/other" 2>/dev/null || true)
        [ "${other_n:-0}" -gt 0 ] || continue
        hit=$(LC_ALL=C comm -12 "$tmp/mine" "$tmp/other")
        [ -n "$hit" ] || continue
        n_hit=$(printf '%s\n' "$hit" | grep -c . || true)
        detail="${detail}⚠️ 与会话 ${label}（${p}）同时改到 ${n_hit} 个文件：
$(printf '%s\n' "$hit" | sed 's/^/     /')
"
    done < <(git -C "$MAIN_ROOT" worktree list --porcelain | sed -n 's/^worktree //p')

    printf '%s' "$detail"
    printf '%s' "$warn"
    if [ -n "$detail" ]; then
        echo "  → 先对齐归属再动手：不要用 stash/restore 抢（会摘走对方在制品）"
    fi
    if [ "$incomplete" = 1 ]; then
        echo "  ⚠️ 有会话未计入——本次结论不完整（先 git fetch / 确认历史相关）"
    elif [ -z "$detail" ]; then
        echo "  ✅ 无跨会话文件重叠"
    fi
    # 已推到 origin 的改动：rebase 时才会暴露，但提前知道可以安排顺序
    base=$(git -C "$wt" merge-base HEAD origin/$SL_DEV_BRANCH 2>/dev/null || true)
    if [ -n "$base" ]; then
        git -C "$wt" diff --name-only --no-renames "$base" origin/$SL_DEV_BRANCH 2>/dev/null \
            | LC_ALL=C sort -u > "$tmp/origin" || true
        origin_hit=$(LC_ALL=C comm -12 "$tmp/mine" "$tmp/origin")
        if [ -n "$origin_hit" ]; then
            echo "  · origin/$SL_DEV_BRANCH 在你分支之后也改过这些文件（push 前 rebase 可能冲突）："
            printf '%s\n' "$origin_hit" | sed 's/^/     /'
        fi
    fi
    return 0
}

cmd_clean() {
    # ⚠️ 同 cmd_push：local 同行引用前序变量在 bash 3.2 下 unbound，必须分行
    local name="$1"
    validate_name "$name"
    local force="${2:-}"
    local wt="$WT_ROOT/wt-$name"
    local br="wt/$name"
    [ -d "$wt" ] || { echo "ERROR: 无 ${wt}"; exit 1; }
    if [ -e "$wt/.git" ]; then
        _assert_wt_owned "$wt" "$br" || exit 1
    else
        # 空壳（无 .git）无法凭 git 校验归属——至少要求本仓库有 wt/<name> 分支，否则拒绝删除
        if ! git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$br"; then
            echo "ERROR: ${wt} 无 .git 且本仓库无 ${br} 分支——不像本会话的空壳，拒绝删除；确认后手动 rm -rf" >&2
            exit 1
        fi
    fi
    git -C "$MAIN_ROOT" fetch origin "$SL_DEV_BRANCH" --quiet || true
    local unpushed dirty
    unpushed=$(_cherry_unabsorbed "$br")
    if [ "$unpushed" = "CHERRY_FAILED" ]; then
        if [ "$force" != "--force" ]; then
            echo "拒绝清理：无法判定 ${br} 是否已推（git cherry 失败，origin/${SL_DEV_BRANCH} 引用缺失？）——人工核查后 clean ${name} --force"
            exit 1
        fi
        unpushed=0  # --force 显式强制语义，判定失败不拦
    fi
    dirty=$(wt_dirty_count "$wt")
    if [ "$force" != "--force" ] && { [ "$unpushed" -gt 0 ] || [ "$dirty" -gt 0 ]; }; then
        echo "拒绝清理：unpushed=${unpushed} dirty=${dirty}——先 push，或确认丢弃后 clean ${name} --force"
        # 知情权：branch -D 后仅 fsck dangling 可救——不可逆决定前必须看得到将失去什么
        git -C "$MAIN_ROOT" log -1 --format="  分支最后提交: %h %ci %s" "$br" 2>/dev/null | head -c 150; echo
        if git -C "$wt" rev-parse -q --verify REBASE_HEAD >/dev/null 2>&1; then
            echo "  ⚠️ 该 worktree 正处于 rebase 进行中——先解决完再清理"
        fi
        git -C "$wt" status --porcelain 2>/dev/null \
            | grep -vE "${SL_DIRTY_IGNORE:-^$}" | head -10 | sed 's/^/  /'
        [ "$(git -C "$wt" status --porcelain 2>/dev/null | wc -l)" -gt 10 ] && echo "  （dirty 明细已截断，完整用 cd $wt && git status 看）"
        exit 1
    fi
    if [ -d "$wt" ] && [ ! -e "$wt/.git" ]; then
        # /tmp 清理空壳——git remove 会 fatal 炸死（审查 P1-1）；直删目录+分支
        rm -rf "$wt"
        git -C "$MAIN_ROOT" branch -D "$br" 2>/dev/null || true
        echo "OK: 已清理空壳 ${wt}（分支 ${br} 已删）"
        return 0
    fi
    git -C "$MAIN_ROOT" worktree remove --force "$wt"
    git -C "$MAIN_ROOT" branch -D "$br" 2>/dev/null || true
    echo "OK: 已清理 ${wt}（分支 ${br} 已删）"
}

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    start) shift; [ $# -ge 1 ] || { usage; exit 1; }; cmd_start "$@" ;;
    list)  cmd_list ;;
    push)  shift; [ $# -ge 1 ] || { usage; exit 1; }; cmd_push "$@" ;;
    adopt) shift; [ $# -ge 1 ] || { usage; exit 1; }; cmd_adopt "$@" ;;
    clean) shift; [ $# -ge 1 ] || { usage; exit 1; }; cmd_clean "$@" ;;
    prune) shift; cmd_prune "${1:-}" ;;
    gc-dirs) shift; cmd_gc_dirs "${1:-}" ;;
    replicate) cmd_replicate ;;
    audit) cmd_audit ;;
    conflicts) shift; [ $# -ge 1 ] || { usage; exit 1; }; cmd_conflicts "$@" ;;
    *)     usage; exit 1 ;;
esac
