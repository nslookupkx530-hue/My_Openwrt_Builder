# OpenWrt Builder

这是一个基于 GitHub Actions 的 OpenWrt/ImmortalWrt 固件构建仓库，主要用于按设备配置自动拉取源码、注入自定义包、应用默认设置并产出固件。

## 所支持设备列表如下：

## X86系列
- x86 ImmortalWrt，默认 IP：`192.168.30.1`

## GL.iNet系列
- GL.iNet AXT-1800，默认 IP：`192.168.8.1`
- GL-MT3600BE，默认 IP：`192.168.9.1`
- GL-MT5000，默认 IP：`192.168.100.1`

## Cudy系列
- Cudy-TR3000-256MB，默认 IP：`192.168.11.1`

## 其他系列
- JDC-AX6600，默认 IP：`192.168.10.1`
- Tenda BE12 Pro，默认 IP：`192.168.21.1`

## 默认用户名/密码

- `root/password`
- `root/空`

## WIFI名称/密码
- `默认/空`


## 目录结构

- `.github/workflows/`：GitHub Actions 构建与发布入口；`_openwrt-build-device.yml` 是共享的可复用长构建流程。
- `.github/actions/`：发布阶段使用的本地 composite actions。
- `Third-Party/third-party.config`：第三方源/插件相关配置。
- `configs/`：各设备的 .config 配置片段 / 设备映射 / 官方与第三方插件配置。
- `files/<设备名>/etc/uci-defaults/…`：每台设备独立的默认配置（如网络），会被复制到构建树的 `src/files/etc/`。
- `files/etc/`：首次启动时装第三方包，会被复制到构建树的 `src/files/etc/`。
- `shell/`：拼 .config、注入插件、准备包清单。

## 构建流程

1. GitHub Actions 根据 workflow matrix 选择设备和配置文件。
2. 克隆对应 OpenWrt/ImmortalWrt 源码。
3. 执行 `sh/scripts-part1.sh`，处理源码级补丁、默认 IP 等前置修改。
4. 更新并安装 feeds。
5. 注入 `default-settings-m0eak`、`files/` 和设备 `.config`。
6. 执行 `sh/scripts-part2.sh`，清理冲突 Makefile 并克隆第三方自定义包。
7. `make defconfig`、下载依赖、编译固件并上传产物。


完整固件构建建议在 GitHub Actions 中验证。

## 致谢

- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [OpenWrt](https://github.com/openwrt/openwrt)
- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)

## License

[MIT](LICENSE)
