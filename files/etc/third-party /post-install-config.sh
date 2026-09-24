#!/bin/sh
# ============================================================
#  第三方 apk "安装后配置修正"
#
#  调用方：/etc/third-party/install_third_party_apk.sh
#          （开机 S99 安装完成后调用；每次开机也会先调用一次）
#  手动跑：/bin/sh /etc/third-party/post-install-config.sh
#
#  设计约定（以后新增第三方包，照着加一段即可）
#   1) 每段独立判断"包在不在"，不在就跳过 → 段与段之间互不影响
#   2) 每段带一个 TAG，应用成功后写进 $DONE_FILE；
#      已应用过的段不再执行 → 不会覆盖你后来在 LuCI 里手动改的配置
#      想重新应用：删掉 $DONE_FILE 里那一行，或把 TAG 升版本（v1 → v2）
#   3) 只有"包存在 + 未应用过"才动手；这次没装上，下次开机自动补
#   4) 幂等：uci 操作用 set / delete + add_list，重复执行结果一致
# ============================================================

DONE_FILE="/etc/third-party-config.done"
LOG_TAG="third-party-cfg"

log() { echo "[${LOG_TAG}] $*"; logger -t "${LOG_TAG}" "$*" 2>/dev/null || true; }

# ---------------------------------------------------------------- 工具
PACKAGE_MANAGER="$(command -v apk >/dev/null 2>&1 && echo apk || echo opkg)"

pkg_installed() {               # $1 = 包名；apk / opkg 都支持
    case "${PACKAGE_MANAGER}" in
        apk)  apk list --installed 2>/dev/null | grep -qE "^$1-[0-9]" ;;
        opkg) opkg list-installed 2>/dev/null | grep -qE "^$1 " ;;
        *)    return 1 ;;
    esac
}

done_already() { [ -f "${DONE_FILE}" ] && grep -qxF "$1" "${DONE_FILE}" 2>/dev/null; }

mark_done() {
    touch "${DONE_FILE}" 2>/dev/null
    grep -qxF "$1" "${DONE_FILE}" 2>/dev/null || echo "$1" >> "${DONE_FILE}"
}

log "===== 第三方 apk 配置修正开始 ($(date '+%F %T')) ====="

# ============================================================
#  段 1：luci-app-quickfile —— 修正 nginx 配置
#  探测方式：/usr/bin/quickfile（该 apk 的二进制）
# ============================================================
fix_quickfile_nginx() {
    local TAG="quickfile-nginx-v1"

    [ -f /usr/bin/quickfile ] || { log "quickfile: 未安装，跳过"; return 0; }
    done_already "${TAG}" && { log "quickfile: 已应用过（${TAG}），跳过"; return 0; }

    if [ ! -f /etc/config/nginx ]; then
        log "quickfile: 暂无可用的 /etc/config/nginx，本次跳过（下次开机再试）"
        return 0
    fi

    log "quickfile: 正在修正 nginx 配置"

    uci set nginx.global.uci_enable='true'
    uci -q delete nginx._lan 2>/dev/null || true
    uci -q delete nginx._redirect2ssl 2>/dev/null || true

    uci add nginx server
    uci rename nginx.@server[-1]='_lan'

    uci set nginx._lan.server_name='_lan'
    uci add_list nginx._lan.listen='80 default_server'
    uci add_list nginx._lan.listen='[::]:80 default_server'
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci set nginx._lan.access_log='off; # logd openwrt'

    if ! uci commit nginx; then
        log "quickfile: uci commit nginx 失败，本次不记录，下次重试"
        return 1
    fi

    [ -x /etc/init.d/nginx ] && /etc/init.d/nginx restart >/dev/null 2>&1 || true

    mark_done "${TAG}"
    log "quickfile: nginx 配置完成"
    return 0
}

# ============================================================
#  段 2：mosdns —— 预设 DNS 分流配置
#  探测方式：apk/opkg 元数据（内置编译的也能识别）
# ============================================================
fix_mosdns() {
    local TAG="mosdns-config-v1"

    pkg_installed mosdns || { log "mosdns: 未安装，跳过"; return 0; }
    done_already "${TAG}" && { log "mosdns: 已应用过（${TAG}），跳过"; return 0; }

    if [ ! -f /etc/config/mosdns ]; then
        log "mosdns: 暂无 /etc/config/mosdns，本次跳过（下次开机再试）"
        return 0
    fi

    log "mosdns: 正在写入预设配置"

    uci set mosdns.config.enabled='1'
    uci set mosdns.config.custom_local_dns='1'
    uci set mosdns.config.dns_leak='1'

    # 先清空再写，保证幂等（也避免多次执行时 list 里堆重复项）
    uci -q delete mosdns.config.local_dns  2>/dev/null || true
    uci -q delete mosdns.config.remote_dns 2>/dev/null || true

    uci add_list mosdns.config.local_dns='https://dns.alidns.com/dns-query'
    uci add_list mosdns.config.local_dns='https://1.12.12.12/dns-query'

    uci add_list mosdns.config.remote_dns='tls://1.1.1.1'
    uci add_list mosdns.config.remote_dns='tls://8.8.8.8'
    uci add_list mosdns.config.remote_dns='tls://9.9.9.9'
    uci add_list mosdns.config.remote_dns='tls://208.67.222.222'

    uci set mosdns.config.bootstrap_dns='114.114.114.114'

    if ! uci commit mosdns; then
        log "mosdns: uci commit mosdns 失败，本次不记录，下次重试"
        return 1
    fi

    [ -x /etc/init.d/mosdns ] && /etc/init.d/mosdns restart >/dev/null 2>&1 || true

    mark_done "${TAG}"
    log "mosdns: 配置完成"
    return 0
}

# ============================================================
#  段 3：以后新增第三方包，照上面的格式加一个函数，
#        然后在下面"- 各段调用 -"里加一行即可
# ============================================================

# ---------------------------- 各段调用 ----------------------------
fix_quickfile_nginx
fix_mosdns

log "===== 第三方 apk 配置修正结束 ====="
exit 0
