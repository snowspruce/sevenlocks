#!/usr/bin/env bash
# deploy_watchdog.sh —— 部署中断监视（L5 可观测闭环，2026-10-22）
# sevenlocks-v1.14 · 上游真源：上游项目 scripts/deploy_watchdog.sh
#
# 背景：deploy.sh 已写 START/END 历史，但进程被 SIGKILL（或 TERM/HUP 单发后挂起）时
# 没有 END，事后只能靠服务器 mtime/venv 池反推——当日实证 40 分钟才发现。本脚本把
# 「START 无 END」变成可见告警，由 deploy.sh 启动时与 session-wt start 审计内嵌调用，
# 也可独立跑（cron/launchd）。判读口径见 SEVEN_LOCKS.md L5。
#
# 判据：
#   ① **按 pid 配对** START/END（并发/交错写历史不会错配；END 缺失的 START 才是候选）；
#   ② 记录的 pid 仍存活且命令行是 deploy.sh、且 START 年龄 ≤ SL_WATCHDOG_MAX_AGE → 视为
#      正常进行中，不报；超过上限则报「可能挂起」（进程活着不等于健康）；
#   ③ 记录的 pid 已不是 deploy.sh → 报（即使另有部署在跑：外层被杀、内层继续时，
#      中断事实本身仍需被告知；「有活部署就跳过」会让并发期所有孤儿静默）；
#   ④ START 年龄 ≥ SL_WATCHDOG_MIN_AGE（默认 300s）。
#
# 用法：
#   ./scripts/deploy_watchdog.sh                 # 有异常：打印并 exit 1；无异常：打印 OK
#   ./scripts/deploy_watchdog.sh --quiet         # 无异常时零输出（内嵌调用）
#   ./scripts/deploy_watchdog.sh --ack PID...    # 给孤儿 START 补 END（人工确认无残留后销账，
#                                                #   否则每次部署/start 永久重报——2026-10-23 审查 P2）
#   ./scripts/deploy_watchdog.sh --history PATH  # 覆盖历史文件
#   SL_ALERT_CMD='脚本/命令' ./scripts/deploy_watchdog.sh   # 异常报告从 stdin 交给它
#
# 环境变量：
#   SL_HISTORY_LOG          历史文件（默认 /tmp/myproject-deploy-history.log）
#   SL_WATCHDOG_MIN_AGE     秒（默认 300）
#   SL_WATCHDOG_MAX_AGE     秒（默认 7200；存活超过此值仍报「可能挂起」）
set -uo pipefail

SL_HISTORY_LOG="${SL_HISTORY_LOG:-/tmp/myproject-deploy-history.log}"
SL_WATCHDOG_MIN_AGE="${SL_WATCHDOG_MIN_AGE:-300}"
SL_WATCHDOG_MAX_AGE="${SL_WATCHDOG_MAX_AGE:-7200}"

QUIET=0
ACK_PIDS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet) QUIET=1; shift ;;
        --ack)
            shift
            [ $# -ge 1 ] || { echo "ERROR: --ack 需要至少一个 pid（见报告各条 pid=N）" >&2; exit 2; }
            ACK_PIDS="$*"; break ;;
        --history)
            [ $# -ge 2 ] || { echo "ERROR: --history 需要路径参数" >&2; exit 2; }
            SL_HISTORY_LOG="$2"; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: 未知参数 $1" >&2; exit 2 ;;
    esac
done

for _v in SL_WATCHDOG_MIN_AGE SL_WATCHDOG_MAX_AGE; do
    eval "_val=\${$_v}"
    case "$_val" in
        ''|*[!0-9]*) echo "ERROR: ${_v} 必须是非负整数（当前 '${_val}'）" >&2; exit 2 ;;
    esac
done

# ── 销账模式：给孤儿 START 补 END ──
# 与正常检查互斥；必须在下方「无历史即 OK 退出」之前处理（无历史时销账是错误不是 OK）。
# pid 先过数字校验再进 grep（-x 整行匹配，无正则注入面）。
if [ -n "$ACK_PIDS" ]; then
    [ -f "$SL_HISTORY_LOG" ] || { echo "ERROR: 无部署历史（${SL_HISTORY_LOG}），无账可销" >&2; exit 2; }
    for _p in $ACK_PIDS; do
        case "$_p" in ''|*[!0-9]*) echo "ERROR: pid 必须是数字（当前 '${_p}'）" >&2; exit 2 ;; esac
    done
    # 复算 open 集（与下方主流程同款按 pid 配对），确认要销的 pid 确有 START 无 END——
    # 防手滑给不存在的 pid 写出无关 END 行污染历史
    _ack_open=$(mktemp "${TMPDIR:-/tmp}/deploy-watchdog-ack.XXXXXX") || { echo "ERROR: mktemp 失败" >&2; exit 2; }
    awk -F'|' '
        $2 == "START" { pid=$3; sub(/^pid=/, "", pid); open[pid]=$1 "|" $4; next }
        $2 == "END"   { pid=$3; sub(/^pid=/, "", pid); delete open[pid]; next }
        END           { for (p in open) print p "|" open[p] }
    ' "$SL_HISTORY_LOG" > "$_ack_open" 2>/dev/null
    _rc=0
    _acked=""
    for _p in $ACK_PIDS; do
        if awk -F'|' -v p="$_p" '$1 == p { found=1 } END { exit !found }' "$_ack_open"; then
            printf '%s|END|pid=%s|ack=manual by=%s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$_p" "$(whoami 2>/dev/null || echo unknown)" \
                >> "$SL_HISTORY_LOG" 2>/dev/null || { echo "ERROR: 历史文件写入失败（${SL_HISTORY_LOG}）" >&2; _rc=2; continue; }
            _acked="$_acked $_p"
        else
            echo "WARN: pid=$_p 没有未关闭的 START，跳过（可能已销过或 pid 写错）" >&2
            _rc=1
        fi
    done
    rm -f "$_ack_open"
    [ -n "$_acked" ] && echo "OK: 已为孤儿 START 补 END（销账）：$_acked"
    exit "$_rc"
fi

[ -f "$SL_HISTORY_LOG" ] || { [ "$QUIET" = "1" ] || echo "OK: 无部署历史（${SL_HISTORY_LOG}），跳过"; exit 0; }

_epoch() {
    local ts="$1"
    if date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s >/dev/null 2>&1; then
        date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s
    else
        date -d "$ts" +%s 2>/dev/null || echo 0
    fi
}

_pid_is_deploy() {
    local pid="$1" cmd
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
    # 内联命令里出现 deploy.sh（bash -c '… deploy.sh …'、编辑器/分页器打开同名文件）不算
    # 存活部署——否则 pid 复用会把真孤儿判成正常（2026-10-23 审查 P1 实证）
    case "$cmd" in
        *" -c "*|*" -lc "*|*" -ic "*|*" -ec "*|*" -xc "*) return 1 ;;
        *deploy.sh*) return 0 ;;
        *) return 1 ;;
    esac
}

_now=$(date +%s)
_report=""
_n=0

_orphan() {  # $1=ts $2=pid $3=rest
    local ts="$1" pid="$2" rest="$3" ep age age_txt alive=0
    ep=$(_epoch "$ts")
    [ "$ep" -gt 0 ] || return 0
    age=$(( _now - ep ))
    [ "$age" -ge "$SL_WATCHDOG_MIN_AGE" ] || return 0
    if _pid_is_deploy "$pid"; then
        alive=1
        # 活着但超龄：可能挂起（TERM/INT 单发后卡在 ssh/rsync）
        [ "$age" -gt "$SL_WATCHDOG_MAX_AGE" ] || return 0
    fi
    # 记录的进程已不在 → 报（即使另有部署在跑：外层被杀、内层继续时，中断事实本身
    # 仍需被告知；原先「有活部署就跳过」会让并发期所有孤儿静默——2026-10-22 CI 实证）
    if [ "$age" -ge 3600 ]; then age_txt="$(( age / 3600 ))h$(( (age % 3600) / 60 ))m"
    else age_txt="$(( age / 60 ))m"; fi
    _n=$((_n + 1))
    if [ "$alive" = "1" ]; then
        _report="${_report}  ${ts} pid=${pid} ${rest}（已 ${age_txt}，进程仍在——可能挂起）
"
    else
        _report="${_report}  ${ts} pid=${pid} ${rest}（已 ${age_txt}，进程已不在）
"
    fi
}

# 按 pid 配对：awk 单遍（O(n)）——原先每个 END 用 grep 重写整个 open 文件，10k 行实测 39s，
# 而 deploy/session-wt 每次启动都要全量重放（2026-10-23 审查 P2）。awk 也消除了把 pid 拼进
# 正则的注入面（非数字 pid 只影响它自己那一键）。
_open=$(mktemp "${TMPDIR:-/tmp}/deploy-watchdog.XXXXXX") || { echo "ERROR: mktemp 失败" >&2; exit 2; }
trap 'rm -f "$_open"' EXIT

awk -F'|' '
    $2 == "START" { pid=$3; sub(/^pid=/, "", pid); open[pid]=$1 "|" $4; next }
    $2 == "END"   { pid=$3; sub(/^pid=/, "", pid); delete open[pid]; next }
    END           { for (p in open) print p "|" open[p] }
' "$SL_HISTORY_LOG" > "$_open" 2>/dev/null

while IFS='|' read -r pid ts rest; do
    [ -n "${pid:-}" ] || continue
    _orphan "$ts" "$pid" "$rest"
done < "$_open"

if [ "$_n" -eq 0 ]; then
    [ "$QUIET" = "1" ] || echo "OK: 无中断部署（${SL_HISTORY_LOG}）"
    exit 0
fi

printf -v _msg '❌ 部署中断：%s 条 START 无 END（%s）\n%s处置：① pgrep -f '\''rsync|ssh'\'' 确认无残留传输；② 核服务器 mtime 与 .deploy-version；③ 确认无残留后 %s --ack <上面各条 pid> 销账（否则每次部署/start 都会重报）；④ 必要时重跑部署\n' \
    "$_n" "$SL_HISTORY_LOG" "$_report" "$0"
printf '%s' "$_msg"
if [ -n "${SL_ALERT_CMD:-}" ]; then
    if ! printf '%s' "$_msg" | bash -c "$SL_ALERT_CMD" >/dev/null 2>&1; then
        echo "WARN: SL_ALERT_CMD 执行失败（报告仍已打印）" >&2
    fi
fi
exit 1
