#!/bin/bash
# ============================================================
#  scripts/n1/prepare.sh   —— N1 产线：源码准备与补丁（容器内运行）
#  精简自 ffuqiangg/build_openwrt，去掉全部第三方 app 的 vendor/补丁
#
#  维护约定：
#    - 升级时只改下面 PINS 区（IMM_TAG / AMLOGIC_PIN）
#    - 所有补丁走 apply()，自带断言；未生效 → FAILED → 脚本 exit 1
#    - 断言的正则必须来自"实际文件内容"，不能凭猜
# ============================================================
set -u

# ==================== 升级时只改这里 ====================
IMM_TAG="v25.12.2"                 # immortalwrt 版本（必须是存在的 tag）
AMLOGIC_PIN="26.10.0301"           # ophub/luci-app-amlogic 的 tag（唯一保留的第三方 feed）
# ======================================================

FAILED=""                          # 全局失败汇总（必须最先初始化）

p "配置 git"
git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

p "基础变量"
build_date="$(date +%Y.%m.%d)"
imm_version="${IMM_TAG#v}"
. set_env "build_date" "${build_date}"
. set_env "latest_release" "${imm_version}"

# ---------- 克隆 immortalwrt ----------
p "克隆 immortalwrt ${IMM_TAG}"
. set_env "wrtdir" "${workdir}/openwrt"
umask 0022
if clone "${IMM_TAG}" "${immortalwrt_repo}" "${wrtdir}"; then
    p "OK   immortalwrt 克隆成功"
else
    p "!! immortalwrt 克隆失败（tag ${IMM_TAG} 存在吗？）"
    FAILED="${FAILED} immortalwrt克隆"
fi
if ! cd "${wrtdir}"; then
    p "!! 进不去 ${wrtdir}，无法继续"
    exit 1
fi
git config core.filemode false

# ---------- 内核版本（打包 action 要用）----------
p "读取内核版本"
current_version="$(sed -n 's/^KERNEL_PATCHVER:=//p' target/linux/armsr/Makefile)"
k_local="$(sed -n "s/^LINUX_VERSION-${current_version} = //p" target/linux/generic/kernel-${current_version})"
. set_env "current_version" "${current_version}"
. set_env "kernel_version" "${current_version}${k_local}"
p "内核: ${current_version}.y / ${kernel_version}"

# ---------- 唯一保留的第三方 feed ----------
p "拉 luci-app-amlogic"
. set_env "otherdir" "${workdir}/other"
if clone "${AMLOGIC_PIN}" "${amlogic_repo}" "${otherdir}/amlogic"; then
    p "OK   luci-app-amlogic 克隆成功（ref=${AMLOGIC_PIN}）"
else
    p "!! 克隆 luci-app-amlogic 失败（ref=${AMLOGIC_PIN} 存在吗？）"
    FAILED="${FAILED} amlogic克隆"
fi

# ---------- 带断言的补丁工具 ----------
apply() {   # apply <文件> <sed表达式> <验证正则 | 前缀!表示必须不存在> <说明>
    f="$1"; expr="$2"; verify="$3"; desc="$4"
    [ -f "${f}" ] || { p "!! 文件缺失: ${f}  (${desc})"; FAILED="${FAILED} ${desc}"; return 1; }
    sed -i "${expr}" "${f}"
    case "${verify}" in
      !*) grep -qE -- "${verify#!}" "${f}" && { p "!! 未生效: ${desc} → ${f}"; FAILED="${FAILED} ${desc}"; return 1; } ;;
      *)  grep -qE -- "${verify}"   "${f}" || { p "!! 未生效: ${desc} → ${f}"; FAILED="${FAILED} ${desc}"; return 1; } ;;
    esac
    p "OK   ${desc}"
}

append_line() {   # append_line <文件> <整行> <验证正则> <说明>
    f="$1"; line="$2"; verify="$3"; desc="$4"
    [ -f "${f}" ] || { p "!! 文件缺失: ${f}"; FAILED="${FAILED} ${desc}"; return 1; }
    grep -qxF "${line}" "${f}" || printf '%s\n' "${line}" >> "${f}"
    if grep -qE -- "${verify}" "${f}"; then
        p "OK   ${desc}"
    else
        p "!! 未生效: ${desc}"
        FAILED="${FAILED} ${desc}"
    fi
}

# ============ P0 必需：与官方内核/kmods 对齐 ============
p ">>>> P0 必需补丁"

DL_BASE="https://downloads.immortalwrt.org/releases/${imm_version}/targets/armsr/armv8"
VV_URL="${DL_BASE}/profiles.json"
OFF_KVER=""
if wget -qO /tmp/p.json "${VV_URL}" 2>/dev/null || curl -fsSL "${VV_URL}" -o /tmp/p.json 2>/dev/null; then
    jq -r '.linux_kernel.vermagic' /tmp/p.json > .vermagic 2>/dev/null || true
    OFF_KVER="$(jq -r '.linux_kernel.version // empty' /tmp/p.json 2>/dev/null)"
    [ -n "${OFF_KVER}" ] && . set_env "official_kernel_version" "${OFF_KVER}"
else
    p "!! profiles.json 拉取失败：${VV_URL}"
    FAILED="${FAILED} profiles.json"
fi

if [ -s .vermagic ] && grep -qE '^[0-9a-f]{32}$' .vermagic; then
    VG_OFF="$(cat .vermagic)"
    p "OK   官方 vermagic = ${VG_OFF}（kernel ${OFF_KVER:-未知}）"
    # 官方 kmods 目录必须真的存在：98 会保留官方 kmods 行，死链会让 apk update 整体失败
    if [ -n "${OFF_KVER}" ]; then
        KCODE="$(curl -s -o /dev/null -w '%{http_code}' -m 20 "${DL_BASE}/kmods/${OFF_KVER}-1-${VG_OFF}/packages.adb" || echo 000)"
        if [ "${KCODE}" = "200" ]; then
            p "OK   官方 kmods = ${OFF_KVER}-1-${VG_OFF}（packages.adb 200）"
        else
            p "!! 官方 kmods 目录不可达：HTTP=${KCODE}（${OFF_KVER}-1-${VG_OFF}）"
            FAILED="${FAILED} 官方kmods"
        fi
    fi
else
    p "!! 官方 vermagic 抓取失败或格式异常: $(head -c 60 .vermagic 2>/dev/null)"
    FAILED="${FAILED} vermagic抓取"
fi
rm -f /tmp/p.json

apply "./include/kernel-defaults.mk" \
      's/^\(.\).*vermagic$/\1cp $(TOPDIR)\/.vermagic $(LINUX_DIR)\/.vermagic/' \
      'cp \$\(TOPDIR\)/\.vermagic' \
      "vermagic 对齐（官方 kmods 兼容）"

apply "./include/feeds.mk" '/CONFIG_BUILDBOT/d' '!CONFIG_BUILDBOT' "feeds.mk 去掉 BUILDBOT 守卫"
sed -i 's/;)\s*\\/; \\/' ./include/feeds.mk
p "OK   feeds.mk 行尾续行修正（由后面的 make defconfig 兜底验证）"

# ============ P1 建议（上游验证过的组合）============
p ">>>> P1 建议补丁"
append_line "./target/linux/generic/config-${current_version}" 'CONFIG_NETKIT=y' '^CONFIG_NETKIT=y$' "NETKIT 内核选项"
apply "./include/target.mk" 's/Os/O2/g' '!-Os' "编译优化 -O2"
apply "./include/target.mk" \
      's/-mcpu=cortex-a53/&+crypto+crc -fpredictive-commoning -ftree-partial-pre -floop-interchange -fschedule-insns -fsched-pressure -ftree-vectorize -fvect-cost-model=cheap -mno-outline-atomics -fweb -frename-registers -fno-plt/' \
      'cortex-a53\+crypto' "A53 定向优化"

# ============ Feeds ============
p "更新 Feeds"
./scripts/feeds update -f -a
./scripts/feeds install -f -a
./scripts/feeds uninstall onionshare-cli || true

# ============ P2 可选 QoL（断言取自实际内容）============
p ">>>> P2 可选 QoL"
apply "./feeds/luci/applications/luci-app-samba4/root/usr/share/luci/menu.d/luci-app-samba4.json" \
      's/nas/services/g' 'admin/services' "samba4 菜单移到「服务」"
apply "./feeds/luci/applications/luci-app-hd-idle/root/usr/share/luci/menu.d/luci-app-hd-idle.json" \
      's/nas/services/g' 'admin/services' "hd-idle 菜单移到「服务」"
apply "./package/system/rpcd/files/rpcd.config" 's/option timeout 30/option timeout 60/g' 'option timeout 60' "rpcd 超时 60s"

# ============ 晶晨宝盒 ============
p "装载晶晨宝盒"
mkdir -p ./package/add
if [ -d "${otherdir}/amlogic/luci-app-amlogic" ]; then
    cp -rf "${otherdir}/amlogic/luci-app-amlogic" ./package/add/
    p "OK   晶晨宝盒已装入"
else
    p "!! 找不到 ${otherdir}/amlogic/luci-app-amlogic（克隆失败？）"
    FAILED="${FAILED} 晶晨宝盒"
fi

# ============ 自定义文件（公共层）============
p "复制自定义文件"
mkdir -p ./files
rm -rf ./files/etc
cp -rf "${ffdir}/files/etc" ./files/
if [ -d ./files/etc/uci-defaults ] && [ -n "$(ls -A ./files/etc/uci-defaults 2>/dev/null)" ]; then
    p "OK   自定义文件已复制 → ./files/etc（uci-defaults $(ls -1 ./files/etc/uci-defaults | wc -l) 个）"
else
    p "!! 复制失败：./files/etc/uci-defaults 为空（源：${ffdir}/files/etc）"
    FAILED="${FAILED} 自定义文件"
fi
chmod 0755 ./files/etc/uci-defaults/* 2>/dev/null || true
find ./files/etc/uci-defaults -maxdepth 1 -type f -exec ls -l {} \;

# N1 不要自建 kmods 源
rm -f ./files/etc/uci-defaults/99-dsf-own-kmods 2>/dev/null || true
if [ -f ./files/etc/uci-defaults/98-drop-kmods-repo ]; then
    p "OK   98-drop-kmods-repo 在位（N1 用官方 kmods，此脚本保持原样）"
else
    p "??   没有 98-drop-kmods-repo（N1 官方 kmods 不依赖它，仅提示）"
fi

# ---- docker 门控：WANT_DOCKER=yes 保留 init.d 脚本；=no 从固件里删干净 ----
#   仓库侧只提供：files/etc/init.d/docker-firewall
#                 （可选）files/etc/rc.d/{S99,K10}docker-firewall
#   files/etc/uci-defaults/99-docker-enable 由 workflow 在构建期生成（仓库不放，避免两份真源）
WANT_DOCKER="${WANT_DOCKER:-no}"

DF_NEED="./files/etc/init.d/docker-firewall"
DF_OPT="./files/etc/rc.d/S99docker-firewall ./files/etc/rc.d/K10docker-firewall"

if [ "${WANT_DOCKER}" = "yes" ]; then
    if [ -f "${DF_NEED}" ]; then
        p "OK   WANT_DOCKER=yes → 保留 ${DF_NEED#./}"
    else
        p "!! 仓库里找不到 ${DF_NEED#./}"
        FAILED="${FAILED} ${DF_NEED#./}"
    fi
    for f in ${DF_OPT}; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            p "OK   构建期软链在位 ${f#./}"
        else
            p "..   无 ${f#./}（正常：首启 99-docker-enable 会 docker-firewall enable 补出来）"
        fi
    done
else
    for f in ${DF_NEED} ${DF_OPT}; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            rm -f "$f"
            p "OK   未启用 docker → 已从固件中移除 ${f#./}"
        fi
    done
fi

# ============ 清理 ============
p "清理"
rm -rf "${otherdir}"
find ./ -name '*.orig' -delete 2>/dev/null || true
find ./ -name '*.rej' -delete 2>/dev/null || true

# ============ 关键值汇总（便于日志核对）============
p "关键值汇总"
p "  wrtdir          = ${wrtdir}"
p "  本仓库(ffdir)   = ${ffdir}"
p "  内核            = ${current_version}.y / ${kernel_version}"
p "  官方内核/vermagic = ${OFF_KVER:-未知} / $(cat .vermagic 2>/dev/null)"
p "  AMLOGIC_PIN     = ${AMLOGIC_PIN}"
p "  WANT_DOCKER     = ${WANT_DOCKER:-no}"
p "  files 文件数     = $(find ./files -type f 2>/dev/null | wc -l)"

[ -z "${FAILED}" ] || { p "!! 以下步骤未生效，构建中止:${FAILED}"; exit 1; }
p "容器内脚本结束"
