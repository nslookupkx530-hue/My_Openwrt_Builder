#!/bin/sh
# ============================================================
#  第三方 apk "安装后配置修正"
#
#    每一段用【永久 id】记录在 $DONE_FILE 里。
#    一旦某段应用过一次，之后【永远不会再碰】对应配置 ——
#    想重新应用某段：删掉 $DONE_FILE 里那一行（如 mosdns）再重启。
#
#  调用方：/etc/third-party/install_third_party_apk.sh
#          （开机 S99 安装完成后调用；每次开机调用一次）
#
# ============================================================
# 常用命令备忘
#   查看已应用段：  cat /etc/third-party-config.done
#   重新应用某段：  sed -i '/^mosdns$/d' /etc/third-party-config.done && reboot
#   手动回滚备份：  cp /etc/third-party-config.bak/mosdns /etc/config/mosdns
#                   /etc/init.d/mosdns restart
# ============================================================
#      已应用过的段不再执行 → 不会覆盖你后来在 LuCI 里手动改的配置
#      只有"包存在 + 未应用过"才动手；这次没装上，下次开机自动补
#      幂等：uci 操作用 set / delete + add_list，重复执行结果一致
# ============================================================

DONE_FILE="/etc/third-party-config.done"
BAK_DIR="/etc/third-party-config.bak"
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

# 应用成功后备一份配置：只作为你手动回滚的后路，脚本自己绝不会去恢复它
backup_cfg() {                  # $1 = config 名（即 /etc/config/<name>）
    [ -f "/etc/config/$1" ] || return 0
    mkdir -p "${BAK_DIR}" 2>/dev/null
    if cp -f "/etc/config/$1" "${BAK_DIR}/$1" 2>/dev/null; then
        log "已备份 /etc/config/$1 → ${BAK_DIR}/$1"
    fi
}

log "===== 第三方 apk 配置修正开始 ($(date '+%F %T')) ====="

# ---------------------------------------------------------------- 保留加固
# 让 .done 在 sysupgrade（保留设置）时也被保留下来。
# 否则刷机后标记丢失 → 已应用过的段会重新应用 → 覆盖你手动改过的配置。
if [ -f /etc/sysupgrade.conf ] && ! grep -qxF "${DONE_FILE}" /etc/sysupgrade.conf 2>/dev/null; then
    echo "${DONE_FILE}" >> /etc/sysupgrade.conf
    log "已把 ${DONE_FILE} 加入 /etc/sysupgrade.conf（sysupgrade 时保留）"
fi
# 想让备份目录也跨 sysupgrade 保留，就再加一行：
#   grep -qxF "${BAK_DIR}" /etc/sysupgrade.conf 2>/dev/null || echo "${BAK_DIR}" >> /etc/sysupgrade.conf

# ============================================================
#  段 1：luci-app-quickfile —— 修正 nginx 配置
#  永久 id：quickfile-nginx
# ============================================================
fix_quickfile_nginx() {
    local SECTION="quickfile-nginx"

    [ -f /usr/bin/quickfile ] || { log "quickfile: 未安装，跳过"; return 0; }
    done_already "${SECTION}" && { log "quickfile: 已应用过（${SECTION}），永不再动"; return 0; }

    if [ ! -f /etc/config/nginx ]; then
        log "quickfile: 暂无 /etc/config/nginx，本次跳过（下次开机再试）"
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

    backup_cfg nginx
    mark_done "${SECTION}"
    log "quickfile: nginx 配置完成（已记录 ${SECTION}，之后永不再动）"
    return 0
}

# ============================================================
#  段 2：mosdns —— 预设 DNS 分流配置
#  永久 id：mosdns
# ============================================================
fix_mosdns() {
    local SECTION="mosdns"

    pkg_installed mosdns || { log "mosdns: 未安装，跳过"; return 0; }
    done_already "${SECTION}" && { log "mosdns: 已应用过（${SECTION}），永不再动"; return 0; }

    if [ ! -f /etc/config/mosdns ]; then
        log "mosdns: 暂无 /etc/config/mosdns，本次跳过（下次开机再试）"
        return 0
    fi

    log "mosdns: 正在写入预设配置"

    uci set mosdns.config.enabled='1'
    uci set mosdns.config.custom_local_dns='1'
    uci set mosdns.config.dns_leak='1'

    # 先清空再写，保证幂等（避免重复执行时 list 里堆重复项）
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

    backup_cfg mosdns
    mark_done "${SECTION}"
    log "mosdns: 配置完成（已记录 ${SECTION}，之后永不再动）"
    return 0
}

# ============================================================
#  段 3：以后新增第三方包，照上面格式加函数
#        要点：SECTION 用永久 id（不要带版本号）；
#              探测包是否存在 → done_already → 改配置 → commit →
#              重启对应服务 → backup_cfg → mark_done
# ============================================================

# ---------------------------- 各段调用 ----------------------------
fix_quickfile_nginx
fix_mosdns

log "===== 第三方 apk 配置修正结束 ====="
exit 0
