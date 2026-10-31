# WuwaTappo Full Community 1.2.4

修 1.2.3 发出去之后发现的两个问题：Windows 装完打不开，以及打 tag 不会自动发版。

## 这次的变化

- **Windows 不再要求安装目录里自带 Chromium 内核**。1.2.3 的安装包把浏览器路径钉死在 `<安装目录>\runtime`，而发行包根本不带这个目录，于是双击直接报「找不到 WebView2」退出。现在入口 stub 会先检查该目录是否存在，不存在就不指定路径，交给 WebView2 自己去找机器上的系统运行时（Win11 自带；Win10 多半也随 Edge 装过）。安装器同时把这个检查提前到安装阶段，缺了会给出官方下载入口，而不是等你双击才炸。
- **打 tag 就是发版**。之前 `publish` 固定带 `--draft`，推完 tag 只产出一个草稿，Releases 列表里看不到，很容易被当成「没发版」。现在四件产物齐全就直接发布；`-alpha` / `-beta` / `-rc` 自动标 Pre-release 不抢 Latest，正式号自动成为 Latest。
- **发版可以重跑自愈**。同 tag 的 Release 已存在时，重跑会补齐文件、同步标题和说明、并把草稿转正，网页上建错了也能修回来。
- **国际服构建不再拉错缓存**。缓存准备脚本在工作目录没有 `local_config.json` 时一律走国服源，在别的机器上构建国际服会把国服素材混进去。现在按 `local_config > WUWA_REGION > 国服` 分派，与 `region.ps1` 一致。
- **换缓存目录抗干扰**。杀软或索引服务短暂占用目录会让改名抛 `WinError 5`，改成 5 次递增退避重试。

## 安装

- **macOS**：Apple Silicon / macOS 13 及以上，下载对应区服的 `.dmg`，拖入「应用程序」。应用使用 Ad hoc 签名，未通过 Apple 公证，首次打开如被拦截请在「系统设置 → 隐私与安全性」里放行。
- **Windows**：Windows 10/11 x64，下载对应区服的 `.exe` 运行安装。装完用桌面快捷方式启动。首次启动会请求管理员权限（本地素材服务需要）。

## 和 1.2.3 的关系

1.2.3 的 Windows 安装包带上面那个 WebView2 缺陷，已经下载过的请改用 1.2.4。macOS 侧功能一致，不必重下。

四件产物：

- `WuwaTappo-Full-CN-Community-1.2.4-macOS-arm64.dmg`
- `WuwaTappo-Full-Global-Community-1.2.4-macOS-arm64.dmg`
- `WuwaTappo-Full-CN-Community-Windows-x64-1.2.4.exe`
- `WuwaTappo-Full-Global-Community-Windows-x64-1.2.4.exe`
