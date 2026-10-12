#!/bin/bash
# ============================================================
#  scripts/n1/init.sh   —— N1 产线的容器准备（宿主侧执行）
#  精简自 ffuqiangg/build_openwrt 的 scripts/init.sh
#  与原始版本的差异：
#    1) Docker 镜像用 digest 固定（不再用 :latest）
#    2) 只保留本项目要用的仓库变量（immortalwrt / amlogic），删掉其余 20 个
#    3) mkdir 改 -p、useradd 加 || true → 重复执行不会中断
#  ⚠️ 故意不加 set -e / set -u：set_env 在宿主侧会引用尚未定义的 ${workdir}
# ============================================================

sudo timedatectl set-timezone 'Asia/Shanghai' 2>/dev/null || true

IMAGE="ffuqiangg/opbe@sha256:45de14313f3c4d589d56d54653a0e7a386f33057818df2442c21302727e16125"

echo "创建快捷命令"
bin_host="${HOME}/bin_host"
mkdir -p "${bin_host}"

# --- 1. set_env：设置变量并同步回宿主 GITHUB_ENV ---
cat <<'EOF' > "${bin_host}/set_env"
#!/bin/bash
SYNC_FILE="${workdir}/.env_sync"
CI_ENV_FILE="${workdir}/ci_env"

p "set_env: $1 = $2"
export "$1"="$2"

if [ -n "${workdir:-}" ] && [ -d "${workdir}" ]; then
    if [ -w "${workdir}" ] || [ -w "${CI_ENV_FILE}" ]; then
        echo "export $1=\"$2\"" >> "${CI_ENV_FILE}"
    fi
    echo "$1=$2" >> "${SYNC_FILE}"
    chmod 666 "${SYNC_FILE}" 2>/dev/null || true
fi

if [ -z "${workdir:-}" ] && [ -n "${GITHUB_ENV:-}" ]; then
    echo "$1=$2" >> "$GITHUB_ENV"
fi
EOF

# --- 2. p：打印 ---
cat <<'EOF' > "${bin_host}/p"
#!/bin/bash
echo "    >> $*"
EOF

# --- 3. d：容器内以 runner 身份执行 + 同步变量回宿主 ---
cat <<'EOF' > "${bin_host}/d"
#!/bin/bash
p "runner@opbe: $*"
docker exec -u runner -e BASH_ENV=${workdir}/ci_env opbe bash -c "$*"
EXIT_CODE=$?
HOST_SYNC_FILE="${workdir_host}/.env_sync"
if [ -f "$HOST_SYNC_FILE" ] && [ -s "$HOST_SYNC_FILE" ]; then
    cat "$HOST_SYNC_FILE" >> "$GITHUB_ENV"
    > "$HOST_SYNC_FILE"
fi
exit $EXIT_CODE
EOF

# --- 4. dr：容器内以 root 身份执行 + 同步变量回宿主 ---
cat <<'EOF' > "${bin_host}/dr"
#!/bin/bash
p "root@opbe: $*"
docker exec -u root -e BASH_ENV=${workdir}/ci_env opbe bash -c "$*"
EXIT_CODE=$?
HOST_SYNC_FILE="${workdir_host}/.env_sync"
if [ -f "$HOST_SYNC_FILE" ] && [ -s "$HOST_SYNC_FILE" ]; then
    cat "$HOST_SYNC_FILE" >> "$GITHUB_ENV"
    > "$HOST_SYNC_FILE"
fi
exit $EXIT_CODE
EOF

# --- 5. clone：浅克隆（只接受分支名或 tag，**不接受裸 commit SHA**）---
cat <<'EOF' > "${bin_host}/clone"
#!/bin/bash
if [ $# -lt 2 ]; then
    echo "用法: clone <branch|tag> <repo_url> <target_dir>" >&2
    return 1 2>/dev/null || exit 1
fi
p "浅克隆: $2 (ref: $1) $3"
git clone -q --filter=blob:none --single-branch -b "$1" "$2" "$3"
EOF

chmod +x "${bin_host}"/*
echo "${bin_host}" >> "$GITHUB_PATH"
export PATH="${bin_host}:${PATH}"

p "打印可用空间"
df -h

p "准备编译容器"
. set_env "workdir" "/ci"
. set_env "workdir_host" "/mnt${workdir}"
. set_env "ffdir" "${workdir}/ffos"

sudo mkdir -p "${workdir_host}"
sudo chown -R runner:runner "${workdir_host}" 2>/dev/null || true

docker pull "${IMAGE}"

docker run -d --name opbe \
    -v "${workdir_host}:${workdir}" \
    -v "${bin_host}:/usr/local/bin_host" \
    -e PATH="/usr/local/bin_host:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e workdir="${workdir}" \
    -e workdir_host="${workdir_host}" \
    -e ffdir="${ffdir}" \
    -e BASH_ENV="${workdir}/ci_env" \
    -w "${workdir}" \
    "${IMAGE}" tail -f /dev/null

p "初始化容器环境文件"
dr "touch ${workdir}/ci_env"
dr "chmod 777 ${workdir}/ci_env"
dr '. set_env workdir "${workdir}"'
dr '. set_env workdir_host "${workdir_host}"'
dr '. set_env ffdir "${ffdir}"'

p "确保用户一致并配置 sudo"
dr "mkdir -p /etc/sudoers.d"
dr "groupadd -g 1001 runner || true"
dr "useradd -u 1001 -g 1001 -m -s /bin/bash runner || true"
dr "echo 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/runner"
dr "chmod 0440 /etc/sudoers.d/runner"
dr "chown -R runner:runner /home/runner"

p "写入本项目需要的仓库变量"
d '
    . set_env "immortalwrt_repo" "https://github.com/immortalwrt/immortalwrt"
    . set_env "amlogic_repo" "https://github.com/ophub/luci-app-amlogic"
'

p "复制仓库到容器内 ${ffdir}"
rm -rf "${workdir_host}/ffos"
cp -r "${GITHUB_WORKSPACE}" "${workdir_host}/ffos"

p "外部脚本结束"
