#!/bin/bash
# sevenlocks-v1.17 · deploy-skeleton.sh —— 部署层（L5）通用段骨架：
#   全局排队锁（mkdir 原子 + 写回校验 + 内外层 pid 锚定）+ CI 门禁分级 + 会话公告
#   + 隔离部署树（DEPLOY_REF fail-closed + 单调前进闸 + 内层重入）+ 排队语义。
# 服务段是定制插槽（扩展点）（文末 deploy_services()）——按「staging→预检→原子切换→健康检查→
# 回滚」骨架逐服务实现，勿动通用段。
# 上游真源：上游项目 scripts/deploy.sh（锁段 / CI 门禁段 / 隔离段，行内注释即出处）
# ——通用逻辑升级照 diff 同步到上游，勿魔改本副本。
# 参考架构：docs/SEVEN_LOCKS.md（七层总览 / 零中断切换 / 三层复用模型）。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ===== 参数层（每项目改这里）=====
SL_DEV_BRANCH="kewang"                    # 部署源分支（部署树 = origin/<它>）
SL_REPO_SLUG="owner/repo"                 # gh api repos/<slug>/actions/runs
SL_GH_ACCOUNT=""                          # 查 CI 用的 gh 账号：空=本机活跃账号；
                                          #   仓库属另一账号时必填（如 some-bot-account）——活跃账号
                                          #   对它 404 时门禁会永远 fail-closed（跨账号实测坑）
SL_LOCK_DIR="/tmp/myproject-deploy.lock"  # 全局锁（绝对路径 ⇒ 跨 checkout 共享）
SL_HISTORY_LOG="/tmp/myproject-deploy-history.log"  # 部署历史留痕（START/END 各一行；中断可判）
SL_NOTICE_FILE="/tmp/myproject-session-notice.txt"
SL_SERVER="user@host"                     # 部署目标（示例）
SL_SELF_RE="deploy-skeleton"              # 锁过期判定的进程匹配串（本脚本文件名）
CI_WAIT_TIMEOUT_DEFAULT=900               # CI 等待上限（按 CI 单 run 时长 ×2 设）
SL_LOCK_WAIT=7200                         # 部署排队等待上限 s（紧急可调短；非正整数归一化回 7200）
# 服务清单（定制示例）：每项一个 deploy_<svc> 函数（文末插槽）
# =============================================

log_info()    { echo "ℹ️  $*"; }
log_success() { echo "✅ $*"; }
log_warning() { echo "⚠️  $*" >&2; }
_DH_LAST_ERR=""
log_error()   {
    echo "❌ $*" >&2
    # 失败摘要进部署历史 END 行（reason=）——归因不依赖会话随手重定向的日志
    _DH_LAST_ERR=$(printf '%s' "$*" | tr '\n' ' ' | sed 's/^❌ *//' | tr '|' '/' | cut -c1-160)
}

# ── 会话公告（跨会话转达通道）：文件存在且未过期（首行 until=YYYYMMDD 自毁）则打印
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

# ── CI 门禁（分级语义）：
#   success → 放行；红（completed 非 success）→ 有人值守仅警告 / 无人值守（ASSUME_YES=1）硬拦；
#   排队/超时 → 提示（未知≠红），但无人值守 × runner 进程不在 → 硬拦（结论永远不来）；
#   无 run / gh 不可用 → 拒绝（门禁宁可误拦，有 SKIP_CI_CHECK=1 逃生舱）。
#   cancelled 提示「可能从未执行（pending 被并发推送淘汰）」。
check_ci_status() {
    command -v gh >/dev/null 2>&1 || { log_error "❌ 未安装 gh CLI，无法检查 CI 状态"; return 1; }
    local head_sha token
    head_sha=$(git rev-parse HEAD)
    # 跨账号：仓库属另一 gh 账号时，活跃账号查 runs 会 404 → 门禁永远 fail-closed——
    # 用参数层 SL_GH_ACCOUNT 指定账号取 token
    if [ -n "$SL_GH_ACCOUNT" ]; then
        token=$(gh auth token -u "$SL_GH_ACCOUNT" 2>/dev/null)
    else
        token=$(gh auth token 2>/dev/null)
    fi
    [ -n "$token" ] || { log_error "❌ 无法获取 gh token（gh auth token${SL_GH_ACCOUNT:+ -u $SL_GH_ACCOUNT}）——跨账号仓库检查参数层 SL_GH_ACCOUNT"; return 1; }

    # 入口归一化：CI_WAIT_TIMEOUT 非正整数时回退默认（否则整数比较报错且判假→无上限死等；
    # case 必须测原始值 ${VAR-}：set-but-empty 会漏网）
    case "${CI_WAIT_TIMEOUT-}" in
        ''|*[!0-9]*) CI_WAIT_TIMEOUT=$CI_WAIT_TIMEOUT_DEFAULT ;;
    esac
    [ "$CI_WAIT_TIMEOUT" -gt 0 ] || CI_WAIT_TIMEOUT=$CI_WAIT_TIMEOUT_DEFAULT

    local waited=0 raw combo status conclusion empty_tries=0
    while :; do
        # gh 非 0 退出（401/403/网络）→ raw 置空（管道 exit code 取末命令，先落变量再判）
        raw=$(GH_TOKEN="$token" gh api -X GET \
            "repos/$SL_REPO_SLUG/actions/runs" \
            -f head_sha="$head_sha" -f per_page=1 \
            --jq '.workflow_runs[] | select(.head_sha == "'"$head_sha"'") | .status + "/" + (.conclusion // "")' \
            2>/dev/null) || raw=""
        combo=$(printf '%s' "$raw" | head -1)
        if [ -z "$combo" ]; then
            # 瞬时 API 故障与「真无 run」同形——重试 3 次再定论
            if [ "$empty_tries" -lt 3 ]; then
                empty_tries=$((empty_tries + 1))
                log_info "⏳ CI 查询为空（第 ${empty_tries} 次）——可能瞬时 API 故障，5s 后重试..."
                sleep 5
                continue
            fi
            log_error "❌ HEAD ${head_sha:0:8} 无 CI run（workflow 被删/禁用？本地落后远端？）或 API 不可达（已重试 3 次）"
            return 1
        fi
        status=${combo%%/*}
        conclusion=${combo##*/}
        if [ "$status" = "completed" ]; then
            if [ "$conclusion" = "success" ]; then
                log_success "✅ CI 状态参考：HEAD ${head_sha:0:8} 的 run 为 success"
                return 0
            fi
            if [ "${DEPLOY_ASSUME_YES:-0}" = "1" ]; then
                log_error "❌ CI 结论为 ${conclusion}，且为无人值守部署（DEPLOY_ASSUME_YES=1）——拒绝带红 CI 上线；确认无碍可 SKIP_CI_CHECK=1 重发"
                [ "$conclusion" = "cancelled" ] && log_error "💡 该 run 可能从未执行（pending 被并发推送淘汰）：换最新 head 部署或重跑该 run"
                return 1
            fi
            log_warning "⚠️  CI 结论为 ${conclusion}（仅提示不阻断）——若非 CI 平台故障，建议先自查测试"
            return 0
        fi
        if [ "$waited" -ge "${CI_WAIT_TIMEOUT:-$CI_WAIT_TIMEOUT_DEFAULT}" ]; then
            # 「未知≠红」放行的前提是 CI 终会给出结论；runner 进程不在（休眠唤醒竞态/
            # 常驻服务挂掉）时结论永远不会来——无人值守须拦。runner 在但排队慢仍只提示。
            # ⚠️ 不加本脚本自匹配条件（2026-10-14 审查订正）：运行中脚本的命令行必含
            # SL_SELF_RE，pgrep 自匹配恒真 → 守卫恒不触发。上游真源（deploy.sh CI 段）
            # 只探 actions-runner。
            if [ "${DEPLOY_ASSUME_YES:-0}" = "1" ] && ! pgrep -f "actions-runner" >/dev/null 2>&1; then
                log_error "❌ CI 等待超时（${status}）且本机 runner 进程不在——无人值守拒绝盲部署；确认无碍可 SKIP_CI_CHECK=1"
                return 1
            fi
            log_warning "⚠️  CI 等待超时（状态仍为 ${status}），继续部署（仅提示）——超时可调 CI_WAIT_TIMEOUT"
            return 0
        fi
        log_info "⏳ CI 进行中（${status}），等待完成（已等 ${waited}s / 上限 ${CI_WAIT_TIMEOUT}s）..."
        sleep 15
        waited=$((waited + 15))
    done
}

# ── 全局排队锁（体系的皇冠）：撞锁=排队等待（10s 轮询+60s 心跳打印，上限 SL_LOCK_WAIT（默认 7200s，
#   隐含假设=部署只从单机发起；第二发起方出现须补远程互斥，见 SEVEN_LOCKS.md L5），
#   超时 exit 75 与部署失败区分），不是退出。
#   过期判定 = 外层壳 pid 与 info 第 2 行起的内层 pid 全部死亡（kill -9 只杀壳时内层
#   =真实部署仍在跑）；pid 存活但 command 不再匹配本脚本 = pid 复用，同样过期。
#   过期清理带回写校验（双等待者竞态防双持有者）。SKIP_DEPLOY_LOCK=1 逃生（仅排障）。
deploy_lock_dir="$SL_LOCK_DIR"
acquire_deploy_lock() {
    local waited=0
    while true; do
        if mkdir "$deploy_lock_dir" 2>/dev/null; then
            echo "$$|${1:-all}|$(date +%s)" > "$deploy_lock_dir/info"
            # 写后回读校验：两个等待者同时清理同一把过期锁时，败者的清理能删掉胜者
            # 刚 mkdir、尚未写 info 的空目录 → 双持有者。回读 info 归属他人即让位回循环。
            # ⚠️ head -n 1：info 自内层注册起是两行，直 cut 返回多行恒 ≠ $$（2026-10-13 修）
            if [ "$(head -n 1 "$deploy_lock_dir/info" 2>/dev/null | cut -d'|' -f1)" != "$$" ]; then
                sleep 1   # 回读失配（罕见竞态或写失败）：小睡防紧循环（2026-10-14 同步上游）
                continue
            fi
            return 0
        fi
        local lock_pid=""
        local lock_cmd=""
        local lock_age=0
        # ⚠️ head -n 1：两行 info 直 cut 返回多行 → ps -p 必失败 → 主判据恒判「过期」、
        #    唯一防线只剩内层救援（2026-10-13 实证）
        [ -f "$deploy_lock_dir/info" ] && lock_pid=$(head -n 1 "$deploy_lock_dir/info" 2>/dev/null | cut -d'|' -f1)
        if [ -n "$lock_pid" ]; then
            lock_cmd=$(ps -p "$lock_pid" -o command= 2>/dev/null || true)
        fi
        # info 首字段是自己 = 竞争败战残留：自己没持锁（还在 acquire 循环），清掉重试
        if [ "$lock_pid" = "$$" ]; then
            if mv "$deploy_lock_dir" "${deploy_lock_dir}.self.$$" 2>/dev/null; then
                rm -rf "${deploy_lock_dir}.self.$$" 2>/dev/null || true
            fi
            continue
        fi
        # info 缺失/pid 为空时按目录 mtime 兜底：超过 2 小时视为过期锁
        if [ -z "$lock_pid" ]; then
            local lock_ts
            lock_ts=$(stat -f '%m' "$deploy_lock_dir" 2>/dev/null || stat -c '%Y' "$deploy_lock_dir" 2>/dev/null || echo 0)
            [ -n "$lock_ts" ] && [ "$lock_ts" -gt 0 ] 2>/dev/null && lock_age=$(( $(date +%s) - lock_ts ))
        fi
        local expired=false
        if [ -z "$lock_pid" ] && [ "$lock_age" -gt 7200 ]; then
            expired=true
        elif [ -n "$lock_pid" ] && [ -z "$lock_cmd" ]; then
            expired=true
        elif [ -n "$lock_pid" ] && ! echo "$lock_cmd" | grep -q "$SL_SELF_RE"; then
            expired=true
        fi
        # 内层 pid 兜底：info 首行是隔离壳 pid，真实部署在内层子进程——「kill -9 只杀壳」
        # 时锁仍锚定到活着的内层，内层也退出后才可被判过期
        if [ "$expired" = true ] && [ -s "$deploy_lock_dir/info" ]; then
            local _ip="" _icmd=""
            for _ip in $(tail -n +2 "$deploy_lock_dir/info" 2>/dev/null); do
                case "$_ip" in ''|*[!0-9]*) continue ;; esac
                _icmd=$(ps -p "$_ip" -o command= 2>/dev/null || true)
                if [ -n "$_icmd" ] && echo "$_icmd" | grep -q "$SL_SELF_RE"; then
                    expired=false
                    lock_pid="${_ip}(内层)"
                    break
                fi
            done
        fi
        if [ "$expired" = true ]; then
            log_warning "发现过期部署锁（pid=${lock_pid:-未知}），自动清理"
            # 原子抢占清理权（2026-10-13 修）：rename 到唯一名——同一时刻只有一个清理者能成功，
            # 后续 rm -rf 只删自己的私有副本，闭合「两等待者同清一把死锁 → 双持有者」竞态
            if mv "$deploy_lock_dir" "${deploy_lock_dir}.stale.$$" 2>/dev/null; then
                rm -rf "${deploy_lock_dir}.stale.$$" 2>/dev/null || true
            fi
            continue
        fi
        if [ "$waited" -ge "$SL_LOCK_WAIT" ]; then
            log_error "❌ 另一部署仍在进行（pid=${lock_pid:-未知}，排队等待超上限 ${SL_LOCK_WAIT}s；锁: ${deploy_lock_dir}——确认确无部署后可 rm -rf）；紧急可 SKIP_DEPLOY_LOCK=1"
            return 1
        fi
        [ $((waited % 60)) -eq 0 ] && log_info "⏳ 另一部署正在进行（pid=${lock_pid:-未知}），排队等待中…（已等 ${waited}s / 上限 ${SL_LOCK_WAIT}s）"
        sleep 10
        waited=$((waited + 10))
    done
}
release_deploy_lock() {
    [ -f "$deploy_lock_dir/info" ] || return 0
    # rm 失败不得中断 trap 链后续清理（EXIT trap 内 set -e 会截断同链命令）
    # ⚠️ head -n 1：两行 info 直 cut 恒 ≠ $$ → 释放恒被跳过、每次隔离部署留残锁（2026-10-13 实证）
    if [ "$(head -n 1 "$deploy_lock_dir/info" 2>/dev/null | cut -d'|' -f1)" = "$$" ]; then
        rm -rf "$deploy_lock_dir" 2>/dev/null || true
    fi
    return 0
}

# ── 部署前 Git 校验（防「部署的代码不是你以为的」）：工作区干净 + HEAD 已推远端。
#   隔离部署模式下由隔离树天然满足。逃生舱 SKIP_GIT_CHECK=1。
check_git_clean() {
    [ "${SKIP_GIT_CHECK:-0}" = "1" ] && { log_warning "⏭️  SKIP_GIT_CHECK=1 跳过 git 校验"; return 0; }
    if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]; then
        log_error "❌ 工作区有未提交改动——部署内容不确定；提交/stash 后重试，或走隔离部署树"
        return 1
    fi
    git fetch origin "$SL_DEV_BRANCH" --quiet || true
    if ! git merge-base --is-ancestor HEAD "origin/$SL_DEV_BRANCH" 2>/dev/null; then
        log_error "❌ HEAD 有未推送到 origin/${SL_DEV_BRANCH} 的提交（或本地落后）——先 push 再部署"
        return 1
    fi
    return 0
}

cleanup() { :; }   # 定制内容：临时文件清理挂这里（锁释放之外的第二清理点）

ORIG_ARGS="$*"
main() {
    print_session_notice

    # 危险组合守卫：无人值守 × 跳过 CI = 零 CI 防线——须再显式二次确认变量
    if [ "${SKIP_CI_CHECK:-0}" = "1" ] && [ "${DEPLOY_ASSUME_YES:-0}" = "1" ] && [ "${CI_SKIP_CONFIRMED:-0}" != "1" ]; then
        log_error "❌ 无人值守（DEPLOY_ASSUME_YES=1）叠加 SKIP_CI_CHECK=1 = 零 CI 防线部署——需再显式设 CI_SKIP_CONFIRMED=1（自担）"
        exit 1
    fi

    # ① 全局锁（先取锁再 fetch——锁内看到的 ref 就是部署的 ref，TOCTOU 闭合；
    #    内层隔离重入必须跳过：锁由隔离壳持有，内层再取必死锁）
    # 部署历史留痕（2026-10-16 实战件移植）：外层壳 START/END 各一行——中断的部署
    # 不再零痕迹（实证：一次被中断的部署树同步+重启完成、健康/版本戳未跑且无记录，
    # 靠服务器 mtime 反推 40 分钟）。判读口径（实测矩阵）：无 END=SIGKILL 硬杀**或 INT 单发
    # 挂起**（先 pgrep 确认进程不在跑）；END rc=0 但服务无新版本戳=可疑中断（TERM/HUP 下
    # bash 执行 EXIT trap 但内部 $? 恒 0；单发 TERM/HUP 还会残留前台 ssh/rsync 子进程，处置
    # =pgrep 清残留）；END rc∉{0,75}=显式失败；TIMEOUT 行=排队超时。append 失败不影响部署。
    deploy_history_log="$SL_HISTORY_LOG"
    deploy_history_line() {
        local _reason=""
        if [ "$1" = "END" ] && printf '%s' "${2:-}" | grep -q 'rc=[1-9]'; then
            _reason=" reason=${_DH_LAST_ERR:-未知}"
        fi
        printf '%s|%s|pid=%s|%s%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$$" "${2:-}" "$_reason" \
            >> "$deploy_history_log" 2>/dev/null || true
    }
    # _dh_start/_dh_lock 先于 trap（设 trap 与赋值间退出会让 dur 失真）；_dh_lock 单一真源
    _dh_start=$(date +%s)
    _dh_lock=$([ "${SKIP_DEPLOY_LOCK:-}" = "1" ] && echo skip || echo held)
    # 🔒 内层哨兵校验：DEPLOY_IN_WORKTREE=1 是隔离壳调内层的内部标记，会跳过锁/隔离/闸
    # 三重防线——外部预设（含从源码/日志复制命令）必须拒绝。判据=合法内层 cwd 必带壳写的
    # .deploy-inner（过渡期安全：外层内层同出 ISO_COMMIT 检出，旧外层调旧内层不认哨兵）。
    if [ "${DEPLOY_IN_WORKTREE:-0}" = "1" ]; then
        _sp=$(git -C "$PWD" rev-parse --path-format=absolute --git-path deploy-inner 2>/dev/null || true)
        if [ -n "$_sp" ] && [ -f "$_sp" ]; then
            # 哨兵存在：nonce 必须匹配（存在但不匹配=陈旧/伪造 → 拒绝）
            if [ -z "${DEPLOY_INNER_NONCE:-}" ] || [ "$(cat "$_sp" 2>/dev/null)" != "$DEPLOY_INNER_NONCE" ]; then
                log_error "❌ 内层哨兵 nonce 不匹配（陈旧/伪造的部署树）——拒绝；请用 ./scripts/deploy.sh 重新发起"
                exit 1
            fi
        else
            # 哨兵缺失：仅旧外层过渡放行（父进程直接跑 deploy.sh 脚本、非 -c 内联）
            _pl=$(ps -p "${PPID:-0}" -o command= 2>/dev/null || true)
            # 逐 token 判定：短选项簇含 c（-c/-lc/-ic/-ec…）一律是内联命令——命令行里出现
            # deploy.sh 只是被粘贴的文本，不算旧外层（否则 zsh -lc "…deploy.sh…" 可绕过锁/隔离/闸）
            _ok=0; _has_deploy=0; _inline=0
            # shellcheck disable=SC2086
            for _tok in $_pl; do
                case "$_tok" in
                    --*) ;;
                    -?*) case "$_tok" in *c*) _inline=1 ;; esac ;;
                    */scripts/deploy.sh) _has_deploy=1 ;;
                esac
            done
            [ "$_has_deploy" = "1" ] && [ "$_inline" = "0" ] && _ok=1
            if [ -f "${PWD}/.git" ] && [ "$_ok" = "1" ]; then
                log_warning "⚠️ 内层哨兵缺失，但父进程是 deploy.sh 且 cwd 为链接 worktree——按旧外层过渡放行（检出过旧）"
            else
                log_error "❌ DEPLOY_IN_WORKTREE=1 但当前目录不是隔离部署树（无哨兵且父进程非 deploy.sh 脚本）——外部预设会绕过锁/隔离/闸，已拒绝"
                exit 1
            fi
        fi
    fi
    if [ "${SKIP_DEPLOY_LOCK:-}" != "1" ] && [ "${DEPLOY_IN_WORKTREE:-0}" != "1" ]; then
        if ! acquire_deploy_lock "${ORIG_ARGS:-all}"; then
            deploy_history_line "TIMEOUT" "target=${ORIG_ARGS:-all} waited=${SL_LOCK_WAIT}s"
            exit 75   # 排队超时专用码：区别于部署失败(1)——无人值守可据此重排队而非报故障
        fi
        log_info "🔒 已获取全局部署锁（跨会话/跨 checkout 排队串行）"
        trap '_dh_rc=$?; deploy_history_line "END" "rc=${_dh_rc} dur=$(( $(date +%s) - _dh_start ))s lock=${_dh_lock}"; release_deploy_lock; cleanup' EXIT
    elif [ "${SKIP_DEPLOY_LOCK:-}" = "1" ]; then
        log_warning "⏭️  SKIP_DEPLOY_LOCK=1：跳过全局部署锁（自担风险——并发部署构建是资源事故模式）"
        trap '_dh_rc=$?; deploy_history_line "END" "rc=${_dh_rc} dur=$(( $(date +%s) - _dh_start ))s lock=${_dh_lock}"; cleanup' EXIT
    fi
    # 内层 pid 注册：隔离壳的子进程把真实部署 pid 追加进锁 info
    if [ "${DEPLOY_IN_WORKTREE:-0}" = "1" ] && [ -f "$deploy_lock_dir/info" ]; then
        echo "$$" >> "$deploy_lock_dir/info" 2>/dev/null || true
    fi
    # 中断部署体检：上一次 START 无 END = 被 SIGKILL 或挂起，当时无人知晓。在本次写 START
    # 前检查并大声报出——只报不拦，但会进入本次部署输出，不再有「零痕迹」路径。
    if [ "${DEPLOY_IN_WORKTREE:-0}" != "1" ] && [ -x "${SCRIPT_DIR:-.}/deploy_watchdog.sh" ]; then
        _wd_out=$(SL_HISTORY_LOG="$deploy_history_log" \
            "$SCRIPT_DIR/deploy_watchdog.sh" --quiet 2>&1 || true)
        if [ -n "$_wd_out" ]; then
            log_warning "⚠️ 上一次部署未正常结束（见下）——先确认无残留 ssh/rsync 再继续"
            printf '%s\n' "$_wd_out" | sed 's/^/   /'
        fi
    fi
    # START 留痕（内层隔离不记——一次部署恰好一对 START/END，END 由外层 trap 写）
    if [ "${DEPLOY_IN_WORKTREE:-0}" != "1" ]; then
        deploy_history_line "START" "target=${ORIG_ARGS:-all} lock=${_dh_lock}"
    fi

    # ② 隔离部署树：部署一律从干净临时 worktree 检出 origin/<DEV_BRANCH>（默认）——
    #    他人工作区未提交改动永远不上生产；DEPLOY_REF 可指定版本（显式指定=fetch 失败
    #    硬拦，不做本地 stale ref 兜底——fail-open 会部署到 stale ref 且单调闸兜不住）。
    #    部署前打印「服务器当前版本→ref」区间摘要（他人提交可见）+ 单调前进闸。
    if [ "${DEPLOY_ISOLATION:-1}" = "1" ] && [ "${DEPLOY_IN_WORKTREE:-0}" != "1" ]; then
        ISO_REF="${DEPLOY_REF:-origin/$SL_DEV_BRANCH}"
        git fetch origin "$SL_DEV_BRANCH" --quiet || { log_error "fetch origin/${SL_DEV_BRANCH} 失败"; exit 1; }
        case "$ISO_REF" in
            "origin/$SL_DEV_BRANCH") : ;;
            origin/*)
                git fetch origin "${ISO_REF#origin/}" --quiet \
                    || { log_error "❌ fetch ${ISO_REF} 失败（分支被删？网络？）——显式 DEPLOY_REF 不做本地 stale ref 兜底"; exit 1; } ;;
        esac
        ISO_COMMIT=$(git rev-parse --verify "${ISO_REF}^{commit}" 2>/dev/null) \
            || { log_error "DEPLOY_REF '$ISO_REF' 无法解析为 commit（未推送？）"; exit 1; }
        log_info "🧅 会话隔离部署：ref=$ISO_REF → ${ISO_COMMIT:0:8}（本地未提交改动不参与本次部署；DEPLOY_ISOLATION=0 可退回主 checkout 直部）"

        ROLLBACK_RISK=0
        iso_show_range() {  # $1=服务名 $2=服务器当前 commit（读服务器 .deploy-version）
            local nm=$1 cur=$2
            [ -n "$cur" ] || return 0
            if git merge-base --is-ancestor "$cur" "$ISO_COMMIT" 2>/dev/null; then
                log_info "── $nm 当前 ${cur:0:8}，本次将新增以下提交："
                git log --oneline "$cur..$ISO_COMMIT" | sed 's/^/     /'
            else
                ROLLBACK_RISK=1
                log_warning "── $nm 当前 ${cur:0:8} 不是 ${ISO_COMMIT:0:8} 的祖先——本次会回滚该服务已上线的提交！"
                git log --oneline "$ISO_COMMIT..$cur" | sed 's/^/     将回退: /'
            fi
        }
        # 服务器当前版本读取（示例：单一 .deploy-version；多服务请按实版做一次 SSH 批量读 + 逐服务闸）
        # ⚠️ `|| true` 必须：本骨架带 `set -o pipefail`，ssh 失败（255）会让管道非 0 → set -e
        # 直接中止且无任何提示（verify-install 实测复现）。空输出=传输失败/首次部署=盲态。
        SVC_CUR=$(ssh -o ConnectTimeout=10 "$SL_SERVER" "cat /opt/myapp/.deploy-version 2>/dev/null | head -1" 2>/dev/null \
            | sed -n 's/.*commit=\([0-9a-f]*\).*/\1/p' || true)
        [ -n "$SVC_CUR" ] || log_warning "服务器 .deploy-version 读取失败（网络/SSH？）——无区间摘要，确认前请自行核对"
        iso_show_range "myapp" "$SVC_CUR"
        [ "$ROLLBACK_RISK" = "1" ] && log_warning "存在回滚风险：若其他会话刚部署了更新的提交，本次会把它们回退。"

        if [ "${DEPLOY_ASSUME_YES:-0}" != "1" ]; then
            if [ ! -t 0 ]; then
                log_error "❌ 非交互环境且未设 DEPLOY_ASSUME_YES=1——确认提示无法应答；无人值守请显式 DEPLOY_ASSUME_YES=1"
                exit 1
            fi
            read -r -p ">>> 确认以上区间并继续？[y/N] " iso_ans || iso_ans=""
            [[ "$iso_ans" == "y" || "$iso_ans" == "Y" ]] || { log_error "已取消（未部署任何内容）"; exit 1; }
        elif [ "$ROLLBACK_RISK" = "1" ] && [ "${DEPLOY_ALLOW_ROLLBACK:-0}" != "1" ]; then
            # 防倒退闸：ASSUME_YES 跳过人工确认时，回滚风险必须显式确认——否则自动化
            # 场景无人拦截（并行会话从旧 ref 部署即静默回滚已上线修复）
            log_error "已取消：检测到回滚风险（服务器已有本次 HEAD 不含的提交）。确认回滚请设 DEPLOY_ALLOW_ROLLBACK=1"
            exit 1
        fi

        ISO_WT=$(mktemp -d /tmp/deploy-iso.XXXXXX) && rmdir "$ISO_WT"
        git worktree add --detach "$ISO_WT" "$ISO_COMMIT" --quiet
        _NONCE="$$-$(date +%s)-${RANDOM:-0}"
        _SP=$(git -C "$ISO_WT" rev-parse --path-format=absolute --git-path deploy-inner 2>/dev/null || echo "$ISO_WT/.deploy-inner")
        printf '%s' "$_NONCE" > "$_SP"   # 内层哨兵（git admin 目录，树内不可见→不脏 check_git_clean）
        # 信号 trap：SIGTERM/SIGHUP 中断时 bash 无 trap 直接死 → worktree+git 元数据双泄漏
        iso_cleanup() { git worktree remove --force "$ISO_WT" 2>/dev/null || true; }
        trap 'iso_cleanup' INT TERM HUP
        # EXIT trap 单槽：必须链回锁释放，漏链 = 隔离路径退出时全局锁泄漏
        # 留痕 END 也须在此重设（rc 取隔离内层退出码——外层以 exit $iso_rc 收尾；trap 单槽）
        trap '_dh_rc=$?; deploy_history_line "END" "rc=${_dh_rc} dur=$(( $(date +%s) - _dh_start ))s lock=${_dh_lock} iso=1"; release_deploy_lock; iso_cleanup; cleanup' EXIT
        log_info "worktree 就绪，隔离执行 $0 $ORIG_ARGS ..."
        set +e
        ( cd "$ISO_WT" && DEPLOY_IN_WORKTREE=1 DEPLOY_INNER_NONCE="$_NONCE" bash "$ISO_WT/scripts/$(basename "$0")" $ORIG_ARGS )
        iso_rc=$?
        set -e
        iso_cleanup
        exit "$iso_rc"
    fi

    # ③ 以下在隔离树内执行（DEPLOY_IN_WORKTREE=1）
    check_git_clean
    [ "${SKIP_CI_CHECK:-0}" = "1" ] || { check_ci_status || exit 1; }

    # 🧪 闸门试跑模式：锁/隔离/单调/CI 已走完 → 按约定停止，绝不碰服务（验收 drill 用）
    if [ "${DEPLOY_GATE_ONLY:-0}" = "1" ]; then
        log_success "🧪 DEPLOY_GATE_ONLY=1：闸门链已走完，按约定停止（未部署任何服务）"
        release_deploy_lock 2>/dev/null || true
        trap - EXIT
        exit 0
    fi

    # ④ 服务部署（定制插槽（扩展点））
    deploy_services "$@"

    release_deploy_lock
    trap - EXIT
}

# =============================================
# 定制插槽（扩展点）：每服务一段，骨架 = staging 全预备 + 单原子操作（零中断切换）+ 回滚。
# 反模式（实战踩过）：rsync --delete 直打 live + 在 live 上装依赖——旧进程全程跑在
# 被换血的目录上，schema 热读的服务会在半成品上重编译。
# =============================================
deploy_services() {
    local rc=0
    # deploy_myapp || rc=1
    # deploy_api  || rc=1
    log_warning "（骨架未实现服务段——按上方骨架逐服务实现 deploy_<svc>() 并在此登记）"
    return "$rc"
}

# deploy_myapp() 骨架示例（伪代码，按服务形态选原子原语）：
#   1. rsync 源码到 $STAGING（旧服务不中断；--delete 排除表=单一真相源，守卫预演与
#      真实切换共用同一份——server-local 文件全靠排除表活着）
#   2. staging 内预检：语法/依赖校验（venv 先 import 一次 / npm build 干跑）——
#      半成品永远到不了 live
#   3. 原子切换（三选一）：
#      - Python venv 蓝绿：.venv 是符号链接，新 venv 建好后 ln -sfn 换链（真零中断）
#      - 同分区 mv：rename 系统调用，亚秒
#      - rename 交换 + 旧树留 .prev 供回滚；node_modules 硬链接复用（共享 inode 零拷贝）
#   4. 健康检查（60s 就绪窗）：失败 → 用 .prev / venv 上一版自动回滚
#   5. 写 .deploy-version（service=<名> commit=<sha> branch=<分支> deployed_at=<ts>）
#      ——单调前进闸与部署混版本检测都读它

main "$@"
