#!/bin/sh
# 首启安装第三方 APK
# ============================================================
#  第三方 apk 多轮安装（设备端运行）
#    /bin/sh /etc/third-party/install_third_party_apk.sh
#    apk 目录: /usr/share/third-party/*.apk（构建期注入）
#
#  为什么要多轮：
#    apk 是「事务式」的 —— 一个源 404、一个依赖没到位，整个 add 就失败。
#    所以一轮装不上的包留到下一轮再试；任何一轮完全没有进展就停，避免死循环。
#    这样与文件排列顺序（如 luci-app-store 依赖 taskd 排在后面）无关。
#
#  只有全部成功才写 /etc/third-party-apk.stamp；否则下次开机重试。
# ============================================================
set -u

APK_DIR="/usr/share/third-party"
STAMP_FILE="/etc/third-party-apk.stamp"
LOCK_FILE="/tmp/third-party-apk-install.lock"
UPDATE_LOG="/tmp/third-party-apk-update.log"
LOG_TAG="third-party"

MAX_PASSES=5                 # 最多装 5 轮
LOCK_STALE_SEC=1800          # 锁超过 30min 视为陈旧可接管
KEEPALIVE_INTERVAL=60        # 心跳间隔
NET_MAX_RETRIES=12           # apk update 最多探 12 次
NET_INTERVAL=10              # 每次间隔 10s（最坏 120s）

KEEPALIVE_PID=""
FAILED_LIST=""
APK_OPTS=""

log() {
    echo "[${LOG_TAG}] $*"
    logger -t "$LOG_TAG" "$*" 2>/dev/null || true
}

# ----------  进程锁  ----------
file_mtime() {
    stat -c %Y "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null || echo 0
}

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        pid="$(tr -dc '0-9' < "$LOCK_FILE" 2>/dev/null)"
        mtime="$(file_mtime "$LOCK_FILE")"
        now="$(date +%s)"
        age=$(( now - mtime ))
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$mtime" -gt 0 ] && [ "$age" -lt "$LOCK_STALE_SEC" ]; then
            log "已有安装进程在跑 (pid=${pid}, age=${age}s)，本次退出"
            return 1
        fi
        log "接管陈旧锁 (pid=${pid:-?}, age=${age}s)"
    fi
    printf '%s\n' "$$" > "$LOCK_FILE"
    return 0
}

start_keepalive() {
    (
        while : ; do
            sleep "$KEEPALIVE_INTERVAL"
            [ -f "$LOCK_FILE" ] || exit 0
            touch "$LOCK_FILE" 2>/dev/null || exit 0
        done
    ) &
    KEEPALIVE_PID="$!"
}

cleanup() {
    [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null
    rm -f "$LOCK_FILE" 2>/dev/null
}
trap 'cleanup' EXIT INT TERM

# ----------   apk 参数  ----------
detect_apk_opts() {
    if apk add --help 2>&1 | grep -q -- '--allow-untrusted'; then
        APK_OPTS="--allow-untrusted"
    else
        APK_OPTS=""
    fi
    log "apk 附加参数: ${APK_OPTS:-<无>}"
}

# ----------   单个安装  ----------
install_one() {
    pkg="$1"
    [ -f "$pkg" ] || { log "缺少文件: $pkg"; return 1; }

    out="$(apk add $APK_OPTS "$pkg" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log "OK   $(basename "$pkg")"
        return 0
    fi
    log "FAIL $(basename "$pkg"): $(printf '%s' "$out" \
        | grep -iE 'conflict|error|unable|unsatisfied|not found|world' \
        | tail -n 2 | tr '\n' ' ')"
    return 1
}

# ----------   多轮循环安装  ----------
install_queue() {
    queue="$1"
    pass=1
    while [ "$pass" -le "$MAX_PASSES" ]; do
        next=""
        progressed=0
        for pkg in $queue; do
            if install_one "$pkg"; then
                progressed=1
            else
                next="$next $pkg"
            fi
        done
        if [ -z "$next" ]; then
            return 0
        fi
        if [ "$progressed" -eq 0 ]; then
            FAILED_LIST="$next"
            log "第 ${pass} 轮毫无进展，停止重试"
            return 1
        fi
        log "第 ${pass} 轮结束，剩余待装:${next}"
        queue="$next"
        pass=$((pass + 1))
    done
    FAILED_LIST="$queue"
    log "已达最大轮数 ${MAX_PASSES}，仍未全部成功"
    return 1
}

# ----------   网络探测  ----------
wait_network() {
    i=1
    while [ "$i" -le "$NET_MAX_RETRIES" ]; do
        if apk update > "$UPDATE_LOG" 2>&1; then
            log "apk update 成功（第 ${i}/${NET_MAX_RETRIES} 次）"
            return 0
        fi
        log "apk update 失败（第 ${i}/${NET_MAX_RETRIES} 次，${NET_INTERVAL}s 后重试）"
        i=$((i + 1))
        sleep "$NET_INTERVAL"
    done
    return 1
}

# ----------   第三方 apk 配置修正钩子   ----------
# 由 main() 调用；脚本不存在就直接返回
CFG_SCRIPT="/etc/third-party/post-install-config.sh"

run_post_config() {
    [ -f "$CFG_SCRIPT" ] || return 0
    log "-- 调用配置修正脚本: ${CFG_SCRIPT}"
    /bin/sh "$CFG_SCRIPT" || log "-- 配置修正脚本返回非 0（不影响 apk 安装结果）"
    return 0
}

# ----------   LuCI 刷新   ----------
refresh_luci() {
    rm -f  /tmp/luci-indexcache*   2>/dev/null
    rm -rf /tmp/luci-modulecache   2>/dev/null
    [ -x /etc/init.d/rpcd ]   && /etc/init.d/rpcd   restart >/dev/null 2>&1
    [ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1
    log "已清理 LuCI 缓存并重启 rpcd/uhttpd"
}

# ----------   main   ----------
main() {
    log "===== 第三方 apk 安装开始 ($(date '+%F %T')) ====="

    # ---- 先抢锁：把"配置修正 + apk 安装"整体串行，避免并发改 /etc/config ----
    acquire_lock || return 0
    start_keepalive

    # ---- ① 开机"检查"一次配置修正 ----
    #   return 0，配置脚本永远不会再被调用。
    #   注意：这里只是"检查"，已应用过的段会在脚本内部秒退，不会重复写配置。
    run_post_config

    if [ ! -d "$APK_DIR" ]; then
        log "$APK_DIR 不存在，跳过"
        return 0
    fi

    PKGS="$(cd "$APK_DIR" && ls -1 *.apk 2>/dev/null | sort)"
    if [ -z "$PKGS" ]; then
        log "$APK_DIR 下没有 apk，跳过"
        return 0
    fi

    MANIFEST="$(printf '%s\n' "$PKGS" | md5sum | tr -d ' -')"
    if [ -f "$STAMP_FILE" ] && [ "$(tr -d ' \n' < "$STAMP_FILE" 2>/dev/null)" = "$MANIFEST" ]; then
        log "清单未变化（md5=${MANIFEST}），无需安装"
        return 0
    fi

    detect_apk_opts

    QUEUE=""
    for f in $PKGS; do QUEUE="$QUEUE $APK_DIR/$f"; done
    log "待安装 $(printf '%s\n' "$PKGS" | wc -l) 个包"

    # ---- ② 装完后立刻再跑一次：让"本次刚装上的包"当场配上 ----
    if install_queue "$QUEUE"; then
        log "全部安装成功（md5=${MANIFEST}）"
        run_post_config
        printf '%s\n' "$MANIFEST" > "$STAMP_FILE"
        refresh_luci
        return 0
    fi

    log "首轮未全部成功，等网络后整体重试:${FAILED_LIST}"
    if wait_network && install_queue "$QUEUE"; then
        log "重试后全部安装成功（md5=${MANIFEST}）"
        run_post_config
        printf '%s\n' "$MANIFEST" > "$STAMP_FILE"
        refresh_luci
        return 0
    fi

    log "仍有包未装成功，不写 stamp，下次开机重试:${FAILED_LIST}"
    run_post_config
    return 1
}

main "$@"
rc=$?
log "===== 第三方 apk 安装结束 rc=${rc} ====="
exit "$rc"
