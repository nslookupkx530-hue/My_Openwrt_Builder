#!/bin/sh
# ============================================================
#  setup-network-auto.sh
#  按物理网口数量自动配置 LAN / WAN（备用脚本，按需手动调用）
#
#  用法：
#    sh /usr/share/scripts/setup-network-auto.sh
#    DRY_RUN=1 sh /usr/share/scripts/setup-network-auto.sh    # 只演示，不改配置
#    LOGFILE=/tmp/my.log sh /usr/share/scripts/setup-network-auto.sh
#
#  可选：把自定义管理地址写进 /etc/custom_router_ip.txt（如 192.168.1.1）
#
#  规则：
#    0 个物理网口 → 报错退出，不动配置
#    1 个物理网口 → 桥进 br-lan，LAN 用 DHCP（旁路由 / 单臂）
#    ≥2 个物理网口 → 第一个做 WAN(DHCP/DHCPv6)，其余桥进 br-lan，LAN 静态
#
#  执行后生效：/etc/init.d/network restart
#  幂等，可重复执行
# ============================================================

LOGFILE="${LOGFILE:-/tmp/netconfig.log}"
DRY_RUN="${DRY_RUN:-0}"
IP_VALUE_FILE="${IP_VALUE_FILE:-/etc/custom_router_ip.txt}"
DEFAULT_LAN_IP="${DEFAULT_LAN_IP:-192.168.100.1}"

: >>"$LOGFILE" 2>/dev/null || LOGFILE=/dev/null
log() {
    echo "$*"
    [ "$LOGFILE" = "/dev/null" ] || echo "$*" >>"$LOGFILE"
}

# DRY_RUN=1 时只打印 uci 命令，不落盘
U() {
    if [ "$DRY_RUN" = "1" ]; then echo "[DRY] uci $*"; else uci "$@"; fi
}

# ---------- 1. 枚举物理网口 ----------
raw=""
for p in /sys/class/net/*; do
    [ -e "$p/device" ] || continue                 # 只认物理口，排除 lo / 虚拟口
    n="$(basename "$p")"
    case "$n" in eth*|en*) ;; *) continue ;; esac
    raw="$raw $n"
done

# 按数字后缀排序（避免 eth10 排在 eth2 前面）
ifnames="$(printf '%s\n' $raw 2>/dev/null \
    | awk 'NF{ s=$1; sub(/^[^0-9]*/, "", s); if (s == "") s=0; printf "%08d %s\n", s, $1 }' \
    | sort -k1,1n | cut -d' ' -f2- | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

count=0
[ -n "$ifnames" ] && count=$(echo "$ifnames" | wc -w)
log ">>> 检测到物理网口: [${ifnames}]  数量: ${count}"

# ---------- 2. 板级映射（特殊网口顺序在这里加 case） ----------
board_name="$(cat /tmp/sysinfo/board_name 2>/dev/null || echo unknown)"
log ">>> 板型: ${board_name}"

case "$board_name" in
    radxa,e20c|friendlyarm,nanopi-r5c)
        wan_ifname="eth1"; lan_ifnames="eth0"
        log "    板级映射: WAN=${wan_ifname} LAN=${lan_ifnames}"
        ;;
    *)
        wan_ifname="$(echo "$ifnames" | awk '{print $1}')"
        lan_ifnames="$(echo "$ifnames" | cut -d' ' -f2-)"
        log "    默认映射: WAN=${wan_ifname} LAN=${lan_ifnames}"
        ;;
esac

# ---------- 3. 工具函数 ----------
# 找 name='br-lan' 的 device section（匿名 @device[N] 和具名 section 都能命中）
find_brlan_section() {
    uci show network 2>/dev/null \
      | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p" \
      | head -n 1
}

# 重设 br-lan 的 ports（$@ = 端口列表）
set_bridge_ports() {
    sec="$(find_brlan_section)"
    if [ -z "$sec" ]; then
        log "    WARN: 没找到 name='br-lan' 的 device，新建 network.brlan"
        U set network.brlan='device'
        U set network.brlan.name='br-lan'
        U set network.brlan.type='bridge'
        sec='brlan'
    fi
    U -q delete "network.${sec}.ports"
    for port in "$@"; do
        [ -n "$port" ] || continue
        U add_list "network.${sec}.ports=${port}"
    done
    log "    br-lan ports = $*"
    # 确保 lan 接口真的指向 br-lan
    if [ "$(uci -q get network.lan.device)" != "br-lan" ]; then
        U set network.lan.device='br-lan'
    fi
}

valid_ip() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    echo "$1" | awk -F. '{exit !($1<256 && $2<256 && $3<256 && $4<256)}'
}

# ---------- 4. 按数量配置 ----------
case "$count" in
    0)
        log "ERROR: 没有检测到 eth*/en* 物理网口，不修改任何配置"
        log "       若设备是 DSA 命名（lan1/wan 等），本脚本不适用，请手改 /etc/config/network"
        exit 1
        ;;
    1)
        log ">>> 单网口模式: ${ifnames} → LAN(DHCP)"
        set_bridge_ports "$ifnames"
        U set network.lan.proto='dhcp'
        U -q delete network.lan.ipaddr
        U -q delete network.lan.netmask
        U -q delete network.lan.gateway
        U -q delete network.lan.dns
        U -q delete network.wan
        U -q delete network.wan6
        ;;
    *)
        log ">>> 多网口模式: WAN=${wan_ifname}  LAN=${lan_ifnames}"

        U set network.wan='interface'
        U set network.wan.device="$wan_ifname"
        U set network.wan.proto='dhcp'
        U -q delete network.wan.ifname          # 清掉老式写法，避免和 device 冲突

        U set network.wan6='interface'
        U set network.wan6.device="$wan_ifname"
        U set network.wan6.proto='dhcpv6'
        U -q delete network.wan6.ifname

        set_bridge_ports $lan_ifnames

        U set network.lan.proto='static'
        U set network.lan.netmask='255.255.255.0'

        if [ -f "$IP_VALUE_FILE" ]; then
            CUSTOM_IP="$(tr -d ' \t\r\n' < "$IP_VALUE_FILE")"
            if valid_ip "$CUSTOM_IP"; then
                log "    LAN IP = ${CUSTOM_IP}（来自 ${IP_VALUE_FILE}）"
            else
                log "    WARN: '${CUSTOM_IP}' 不是合法 IPv4，回退 ${DEFAULT_LAN_IP}"
                CUSTOM_IP="$DEFAULT_LAN_IP"
            fi
        else
            CUSTOM_IP="$DEFAULT_LAN_IP"
            log "    LAN IP = ${CUSTOM_IP}（默认）"
        fi
        U set network.lan.ipaddr="$CUSTOM_IP"
        ;;
esac

# ---------- 5. 提交 ----------
if [ "$DRY_RUN" = "1" ]; then
    log ">>> DRY_RUN=1：未提交任何改动"
    exit 0
fi

if uci commit network; then
    log ">>> uci commit network 成功"
else
    log "ERROR: uci commit network 失败"
    exit 1
fi
log ">>> 完成。执行 /etc/init.d/network restart 生效"
log "    注意：若通过 LAN 远程操作，地址变化后需要重连"
exit 0
