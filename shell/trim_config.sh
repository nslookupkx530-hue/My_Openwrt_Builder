#!/bin/bash
# ==============================================================================
# trim_config.sh —— 关掉本项目用不到 / 已知编不过的选项
#
# 为什么需要：
#   官方 config.buildinfo 里带了一批开发调试工具（perf、kselftests-* 等），
#   它们对路由器固件没有任何用处，而且经常因内核 config / 工具链差异编译失败：
#       ERROR: package/devel/kselftests-bpf failed to build.
#   这里统一关掉，避免每次构建都死在同一个地方。
#
# 执行位置：buildroot 目录（.config 所在），在 prepare_base_config.sh 之后、
#           workflow 最后一次 make defconfig 之前执行。
# 记录：tmp/trimmed-options.txt（供 workflow 校验它们确实还是关闭状态）
#
# 注意：只关"用不到 + 易失败"的；base-files / busybox / libc 这类基础包不要动。
# ==============================================================================
set -euxo pipefail

CONFIG_FILE=".config"
[ -f "$CONFIG_FILE" ] || { echo "ERROR: 找不到 .config"; exit 1; }

# ------------------------------------------------------------------
# 关闭列表
#   CONFIG_PACKAGE_kselftests-bpf  ← 内核 BPF 自测集，依赖内核 BTF/调试信息，用不到
#   CONFIG_PACKAGE_kselftests-net  ← 同族（源码里没有会自动跳过）
#   CONFIG_PACKAGE_perf            ← 需要时再放开
#   CONFIG_PACKAGE_bpftool
# ------------------------------------------------------------------
TRIM_OPTS="
CONFIG_PACKAGE_kselftests-bpf
CONFIG_PACKAGE_kselftests-net
"

# ------------------------------------------------------------------
# 必须打开的选项
#   CONFIG_PACKAGE_ip-full  ← 第三方包 quickstart（网络向导后端）要求 ip-full
#     官方基线装的是 ip-tiny，两者 CONFLICTS，不换掉就永远装不上 quickstart
# ------------------------------------------------------------------
FORCE_ON_OPTS="
CONFIG_PACKAGE_ip-full
"

# ------------------------------------------------------------------
# 必须关闭的选项（与上面互斥）
#   CONFIG_PACKAGE_ip-tiny
# ------------------------------------------------------------------
FORCE_OFF_OPTS="
CONFIG_PACKAGE_ip-tiny
"

symbol_exists() {
    local sym="${1#CONFIG_}"
    ls tmp/.config-*.in >/dev/null 2>&1 || return 0
    grep -qE "^[[:space:]]*config ${sym}$" tmp/.config-*.in 2>/dev/null
}

set_opt_on() {
    sed -i "/^$1=/d; /^# $1 is not set$/d" "$CONFIG_FILE"
    echo "$1=y" >> "$CONFIG_FILE"
}

set_opt_off() {
    sed -i "/^$1=/d; /^# $1 is not set$/d" "$CONFIG_FILE"
    echo "# $1 is not set" >> "$CONFIG_FILE"
}

mkdir -p tmp
: > tmp/trimmed-options.txt
: > tmp/injected-plugins.txt

# ---------- 关闭 ----------
for opt in ${TRIM_OPTS} ${FORCE_OFF_OPTS}; do
    if ! symbol_exists "${opt}"; then
        echo "  skip ${opt}（当前源码里没有这个选项）"
        continue
    fi
    if grep -q "^${opt}=y" "$CONFIG_FILE"; then
        echo "  off  ${opt}（原本为 y，已关闭）"
    else
        echo "  off  ${opt}（原本就不是 y）"
    fi
    set_opt_off "${opt}"
    echo "${opt}" >> tmp/trimmed-options.txt
done

# ---------- 打开 ----------
for opt in ${FORCE_ON_OPTS}; do
    if ! symbol_exists "${opt}"; then
        echo "WARNING: ${opt} 在当前源码中不存在，跳过"
        continue
    fi
    echo "  on   ${opt}"
    set_opt_on "${opt}"
    echo "${opt}" >> tmp/injected-plugins.txt
done

echo ">>> trim_config 完成：关闭 $(wc -l < tmp/trimmed-options.txt) 项，打开 $(wc -l < tmp/injected-plugins.txt) 项"
