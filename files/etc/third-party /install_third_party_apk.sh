#!/bin/sh

APK_DIR="/usr/share/third-party"
LOG_FILE="/tmp/third-party-apk-install.log"
LOCK_DIR="/tmp/third-party-apk-install.lock"
DONE_FILE="/etc/third-party-apk-installed"

MAX_RETRIES=30
RETRY_INTERVAL=10

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log "=========================================="
log "Starting third-party APK installation"
log "=========================================="

# 成功安装后不再重复执行
if [ -f "$DONE_FILE" ]; then
    log "Third-party APK packages are already installed."
    exit 0
fi

# 防止多个安装进程同时运行
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another installation process is already running."
    exit 0
fi

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null
}

trap cleanup EXIT INT TERM

# 检查 APK 目录
if [ ! -d "$APK_DIR" ]; then
    log "ERROR: APK directory does not exist: $APK_DIR"
    exit 1
fi

# 获取 APK 文件
set -- "$APK_DIR"/*.apk

if [ ! -f "$1" ]; then
    log "No third-party APK packages found."
    exit 0
fi

log "APK packages to install:"

for apk_file in "$@"; do
    log "  $apk_file"
done

# 检查 apk 命令
if [ ! -x /usr/bin/apk ]; then
    log "ERROR: /usr/bin/apk is not available."
    exit 1
fi

# 等待网络可用
log "Waiting for network connectivity..."

COUNT=0

while :; do
    NETWORK_READY=0

    # 优先测试 HTTPS，避免仅通过 ping 判断网络状态
    if command -v uclient-fetch >/dev/null 2>&1; then
        if uclient-fetch \
            -q \
            -O /tmp/third-party-network-test \
            "https://downloads.openwrt.org/" \
            >/dev/null 2>&1; then
            NETWORK_READY=1
        fi

        rm -f /tmp/third-party-network-test

    elif command -v wget >/dev/null 2>&1; then
        if wget \
            -q \
            -O /tmp/third-party-network-test \
            "https://downloads.openwrt.org/" \
            >/dev/null 2>&1; then
            NETWORK_READY=1
        fi

        rm -f /tmp/third-party-network-test

    elif command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            NETWORK_READY=1
        fi
    else
        log "WARNING: No network test command found."
        NETWORK_READY=1
    fi

    if [ "$NETWORK_READY" -eq 1 ]; then
        log "Network connectivity is available."
        break
    fi

    if [ "$COUNT" -ge "$MAX_RETRIES" ]; then
        log "ERROR: Network is not ready after 5 minutes."
        exit 1
    fi

    COUNT=$((COUNT + 1))

    log "Network is not ready. Retrying in ${RETRY_INTERVAL}s (${COUNT}/${MAX_RETRIES})..."

    sleep "$RETRY_INTERVAL"
done

log "Installing third-party APK packages..."

# 不使用 --force-reinstall，避免不必要的重复安装
if ! apk add --allow-untrusted "$@"; then
    log "ERROR: APK installation failed."
    log "Please check APK dependencies and repository connectivity."
    exit 1
fi

log "APK installation completed."

# 清理 LuCI 缓存
log "Refreshing LuCI caches..."

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache

# 重启 LuCI 相关服务
if [ -x /etc/init.d/rpcd ]; then
    /etc/init.d/rpcd restart
fi

if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd restart
fi

# 只有安装成功后才写入完成标志
touch "$DONE_FILE"

log "=========================================="
log "Third-party APK installation completed"
log "=========================================="

exit 0
