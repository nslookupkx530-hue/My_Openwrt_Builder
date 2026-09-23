#!/bin/sh
# 首启安装第三方 APK
#
# 防重复安装三层机制：
#   1) 清单 stamp：/etc/third-party-apk.stamp（apk 文件名清单的 md5，未变即跳过）
#   2) 进程锁：/tmp/third-party-apk-install.lock（含 pid，kill -0 判活 + 1800s 兜底 + 心跳）
#   3) apk 自身幂等：同名同版本不会重复安装
#
# 安装策略：
#   · 多轮循环安装：同一轮里装不上的下一轮再试 → 消除 APK_DIR 内文件顺序对依赖解析的影响
#     （例如 luci-app-store 的依赖 taskd 排在它后面时，第二轮就能装上）
#   · 每轮无进展即停止；全部失败后等 apk 仓库可达再整体重试
#   · 全部成功才写 stamp；有失败不写，下次开机自动重试
#
# ⚠ 不要给 /etc/init.d/apk-install 加 procd respawn

APK_DIR="/usr/share/third-party"
LOG_FILE="/tmp/third-party-apk-install.log"
LOCK_DIR="/tmp/third-party-apk-install.lock"
STAMP_FILE="/etc/third-party-apk.stamp"

LOCK_STALE_SEC=1800
NET_MAX_RETRIES=12
NET_INTERVAL=10
LOCKED=0

log() {
    echo "$(date '+%F %T') $*" | tee -a "$LOG_FILE"
    logger -t third-party-apk "$*" 2>/dev/null
}

keepalive() { touch "$LOCK_DIR" 2>/dev/null; return 0; }

log "===== third-party APK install start ====="

# ---------- 0. 清单与 stamp ----------
[ -d "$APK_DIR" ] || { log "ERROR: 目录不存在: $APK_DIR"; exit 1; }

set -- "$APK_DIR"/*.apk
[ -f "$1" ] || { log "没有找到第三方 APK，跳过"; exit 0; }

STAMP="$(printf '%s\n' "$@" | sed 's#.*/##' | sort | md5sum | cut -d' ' -f1)"
if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE" 2>/dev/null)" = "$STAMP" ]; then
    log "已安装且清单未变（stamp=$STAMP），跳过"
    exit 0
fi

# ---------- 1. 进程锁（pid 判活 + 超时兜底 + 心跳）----------
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        LOCKED=1
        return 0
    fi

    OTHER_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo '')"
    if [ -n "$OTHER_PID" ] && kill -0 "$OTHER_PID" 2>/dev/null; then
        log "已有安装进程在运行（pid=${OTHER_PID}），本次跳过"
        return 1
    fi

    LOCK_TS="$(date -r "$LOCK_DIR" +%s 2>/dev/null || echo 0)"
    LOCK_AGE="$(( $(date +%s) - LOCK_TS ))"
    if [ "$LOCK_AGE" -gt "$LOCK_STALE_SEC" ]; then
        log "WARNING: 清理陈旧锁（pid=${OTHER_PID:-未知}，锁龄 ${LOCK_AGE}s）"
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo $$ > "$LOCK_DIR/pid"
            LOCKED=1
            return 0
        fi
    fi

    log "锁状态不明确（pid=${OTHER_PID:-无}，锁龄 ${LOCK_AGE}s），保守跳过"
    return 1
}
release_lock() { [ "$LOCKED" = "1" ] && rm -rf "$LOCK_DIR"; }
trap 'release_lock' EXIT INT TERM

acquire_lock || exit 0

# ---------- 2. 多轮循环安装 ----------
[ -x /usr/bin/apk ] || { log "ERROR: /usr/bin/apk 不可用"; exit 1; }

FAILED=""
install_queue() {   # 多轮：一轮装不上的下一轮再试，直到没有新进展
    FAILED=""
    LEFT="$*"
    PASS=0
    while [ -n "${LEFT}" ] && [ "${PASS}" -lt "${MAX_PASSES}" ]; do
        PASS=$((PASS + 1))
        NEXT=""
        for f in ${LEFT}; do
            keepalive
            if apk add --allow-untrusted "${f}" >>"${LOG_FILE}" 2>&1; then
                log "  OK   ${f##*/}"
            else
                NEXT="${NEXT} ${f}"
            fi
        done
        if [ -z "${NEXT}" ]; then
            log "  第 ${PASS} 轮：全部成功"
            LEFT=""
            break
        fi
        log "  第 ${PASS} 轮后仍失败：${NEXT}"
        if [ "${NEXT}" = "${LEFT}" ]; then
            log "  本轮没有任何进展，停止重试"
            LEFT="${NEXT}"
            break
        fi
        LEFT="${NEXT}"
    done
    FAILED="${LEFT}"
    [ -z "${FAILED}" ]
}

log "共 $# 个 apk 待安装"
if install_queue "$@"; then
    log "全部安装成功"
else
    log "部分失败，等待 apk 仓库可达后重试：${FAILED}"
    i=0; READY=0
    while [ "$i" -lt "$NET_MAX_RETRIES" ]; do
        i=$((i + 1))
        keepalive
        if apk update >>"${LOG_FILE}" 2>&1; then READY=1; break; fi
        log "仓库不可达，${NET_INTERVAL}s 后重试（${i}/${NET_MAX_RETRIES}）"
        sleep "$NET_INTERVAL"
    done
    if [ "$READY" = "1" ]; then
        if install_queue "${FAILED}"; then
            log "重试后全部成功"
        else
            log "重试后仍有失败：${FAILED}"
        fi
    else
        log "ERROR: 仓库始终不可达，放弃本次重试"
    fi
fi

# ---------- 3. 收尾 ----------
if [ -n "${FAILED}" ]; then
    log "ERROR: 以下包安装失败：${FAILED}"
    log "未写入 stamp，下次开机会自动重试（已装成功的包不会重复安装）"
    exit 1
fi

printf '%s\n' "$STAMP" > "$STAMP_FILE"
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache
[ -x /etc/init.d/rpcd ]   && /etc/init.d/rpcd restart
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart
log "全部安装完成，已写入 stamp"
exit 0
