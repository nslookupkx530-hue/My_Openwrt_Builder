#!/bin/bash
# 容器内运行（由 n1-build.yml 调起）
# 精简自 ffuqiangg/build_openwrt：去掉全部第三方 app 的 vendor 与补丁，只留不可少的 hack
set -u

# ================== 升级时只改这一段 ==================
IMM_TAG="v25.12.4"                       # ← 钉死 immortalwrt tag，不要"现抓最新"
AMLOGIC_PIN="<PIN: ophub/luci-app-amlogic 的 commit>"   # ← 唯一保留的第三方 feed
# ======================================================

p "配置 git"
git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

p "基础变量"
build_date="$(date +%Y.%m.%d)"
imm_version="${IMM_TAG#v}"
. set_env "build_date" "${build_date}"
. set_env "latest_release" "${imm_version}"

p "克隆 immortalwrt ${IMM_TAG} → ${workdir}/openwrt"
. set_env "wrtdir" "${workdir}/openwrt"
umask 0022
clone "${IMM_TAG}" "${immortalwrt_repo}" "${wrtdir}"
cd "${wrtdir}"
git config core.filemode false

p "读取内核版本（打包 action 要用）"
current_version="$(sed -n 's/^KERNEL_PATCHVER:=//p' target/linux/armsr/Makefile)"
kernel_version="$(sed -n "s/^LINUX_VERSION-${current_version} = //p" target/linux/generic/kernel-${current_version})"
. set_env "current_version" "${current_version}"
. set_env "kernel_version" "${current_version}${kernel_version}"
p "内核: ${current_version}.y / ${current_version}${kernel_version}"

p "拉唯一保留的第三方 feed：luci-app-amlogic"
. set_env "otherdir" "${workdir}/other"
clone "${AMLOGIC_PIN}" "${amlogic_repo}" "${otherdir}/amlogic"

# ============ 带断言的补丁工具（核心：补丁静默失效 → 构建直接红）============
FAILED=""
apply() {   # apply <文件> <sed表达式> <验证正则|!必须不存在> <说明>
    f="$1"; expr="$2"; verify="$3"; desc="$4"
    [ -f "${f}" ] || { p "!! 文件缺失: ${f}  (${desc})"; FAILED="${FAILED} ${desc}"; return 1; }
    sed -i "${expr}" "${f}"
    case "${verify}" in
      !*) grep -qE "${verify#!}" "${f}" && { p "!! 未生效: ${desc}"; FAILED="${FAILED} ${desc}"; return 1; } ;;
      *)  grep -qE "${verify}"   "${f}" || { p "!! 未生效: ${desc}"; FAILED="${FAILED} ${desc}"; return 1; } ;;
    esac
    p "OK   ${desc}"
}
append_line() {  # append_line <文件> <整行内容> <验证正则> <说明>
    f="$1"; line="$2"; verify="$3"; desc="$4"
    [ -f "${f}" ] || { p "!! 文件缺失: ${f}"; FAILED="${FAILED} ${desc}"; return 1; }
    grep -qxF "${line}" "${f}" || printf '%s\n' "${line}" >> "${f}"
    grep -qE "${verify}" "${f}" && p "OK   ${desc}" || { p "!! 未生效: ${desc}"; FAILED="${FAILED} ${desc}"; }
}

p ">>>> P0 必需补丁"
wget -qO profiles.json "https://downloads.immortalwrt.org/releases/${imm_version}/targets/armsr/armv8/profiles.json" \
  && jq -r '.linux_kernel.vermagic' profiles.json > .vermagic && [ -s .vermagic ] \
  && p "OK   vermagic 抓取: $(cat .vermagic)" \
  || { p "!! 抓取官方 vermagic 失败"; FAILED="${FAILED} vermagic抓取"; }
rm -f profiles.json
apply "./include/kernel-defaults.mk" \
      's/^\(.\).*vermagic$/\1cp $(TOPDIR)\/.vermagic $(LINUX_DIR)\/.vermagic/' \
      'cp \$\(TOPDIR\)/\.vermagic' "vermagic 对齐（官方 kmods 可用）"
apply "./include/feeds.mk" '/CONFIG_BUILDBOT/d' '!CONFIG_BUILDBOT' "feeds.mk 去掉 BUILDBOT 守卫"
sed -i 's/;)\s*\\/; \\/' ./include/feeds.mk   # 行尾续行修正（真正的校验是后面的 make defconfig）

p ">>>> P1 建议（他验证过的组合）"
append_line "./target/linux/generic/config-${current_version}" 'CONFIG_NETKIT=y' '^CONFIG_NETKIT=y$' "NETKIT 内核选项"
apply "./include/target.mk" 's/Os/O2/g' 'O2' "编译优化 -O2"
apply "./include/target.mk" 's/-mcpu=cortex-a53/&+crypto+crc -fpredictive-commoning -ftree-partial-pre -floop-interchange -fschedule-insns -fsched-pressure -ftree-vectorize -fvect-cost-model=cheap -mno-outline-atomics -fweb -frename-registers -fno-plt/' \
      'cortex-a53\+crypto' "A53 定向优化"

p "更新 Feeds"
./scripts/feeds update -f -a
./scripts/feeds install -f -a
./scripts/feeds uninstall onionshare-cli || true

p ">>>> P2 可选 QoL（纯增量，风险低）"
apply "./feeds/luci/applications/luci-app-samba4/root/usr/share/luci/menu.d/luci-app-samba4.json" 's/nas/services/g' '"services"' "samba4 菜单移到「服务」"
apply "./feeds/luci/applications/luci-app-hd-idle/root/usr/share/luci/menu.d/luci-app-hd-idle.json" 's/nas/services/g' '"services"' "hd-idle 菜单移到「服务」"
apply "./package/system/rpcd/files/rpcd.config" 's/option timeout 30/option timeout 60/g' 'option timeout 60' "rpcd 超时 60s"

p "装载晶晨宝盒"
mkdir -p ./package/add
cp -rf "${otherdir}/amlogic/luci-app-amlogic" ./package/add/

p "复制自定义文件（只取公共层；N1 不要 99）"
mkdir -p ./files
cp -rf "${ffdir}/files/etc" ./files/ || true
rm -f ./files/etc/uci-defaults/99-dsf-own-kmods 2>/dev/null || true

p "清理"
rm -rf "${otherdir}"
find ./ -name '*.orig' -delete 2>/dev/null || true
find ./ -name '*.rej'  -delete 2>/dev/null || true

[ -z "${FAILED}" ] || { p "!! 以下步骤未生效，构建中止:${FAILED}"; exit 1; }
p "容器内脚本结束"
