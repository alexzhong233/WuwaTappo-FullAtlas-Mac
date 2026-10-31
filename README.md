# WuwaTappo FullAtlas Mac

> 当前为 `official-1.0.3` 实验分支：整合版 **1.2.2-alpha.1**，基于官方国服 **1.0.3**。已完成测试、构建与基础窗口检查，尚未完成账号及输入权限实机验收。`main` 保留基于官方 1.0.2 的 1.2.1 预览版。详见 [1.0.3 适配记录](docs/OFFICIAL_1.0.3.md)。

让《鸣潮》桌宠在 Mac 上运行，并在原有面板中加入本地全图鉴和桌面助手。

基于 [wuwa-tappo-mac](https://github.com/Last-emo-boy/wuwa-tappo-mac) 的 Rust / Tauri macOS 后端，以及 [WuwaTappo-FullAtlas](https://github.com/Averionx/WuwaTappo-FullAtlas) 的图鉴和助手功能开发。无需 Windows、Wine 或虚拟机。本项目为非官方社区整合版，与库洛官方及两个上游项目的发行渠道独立。

## 支持情况

| 项目 | 当前状态 |
| --- | --- |
| 服务区域 | 国服；国际服代码保留自上游，未整合 FullAtlas，不作为本项目发行目标 |
| 系统 | Apple Silicon（M 系列），macOS 13 及以上 |
| 整合版本 | 1.2.2-alpha.1 实验版，基于官方国服 1.0.3 与 FullAtlas v1.2 |
| 分支 | `official-1.0.3`；`main` 仍为 1.0.2 基底 |
| 验证 | 自动测试、原生构建、签名与 ZIP / DMG 校验通过；角色和设置面板可显示，完整业务仍需实机验收 |
| 签名 | Ad hoc 临时签名，未通过 Apple 公证 |

## 功能

- 原生透明桌宠、缩放、置顶、鼠标穿透、菜单栏控制和显示器定位。
- 在官方背包 / 图鉴 / 设置面板中加入本地全图鉴开关，可切换账号背包与完整图鉴显示。
- 桌面助手：后台点击、自动开箱、开箱记录、每日统计、房间历史和显示器记忆。自动任务默认关闭。
- 后台点击通过桌宠内部事件工作；物理键鼠活动会暂停自动点击。不会向 macOS 系统注入键盘或鼠标事件。
- 账号登录、计数同步、宝箱冷却、消耗与奖励仍使用官方服务；本地图鉴只改变本地显示，不解锁账号资产。
- 本地图鉴开启时阻止联机房间，以及会把本地外观、收藏或合成写回账号的请求；关闭后恢复普通账号视图。
- 可联网同步公开图鉴目录。图片仍依赖官方素材 CDN，**不是完整离线资源包**。

## 安装与使用

发布后在本仓库的 **Releases** 中下载 `WuwaTappo-FullAtlas-Mac-版本-arm64.dmg`，将应用拖入「应用程序」。ZIP 与 DMG 内的应用相同，只需选一个。

1. 打开 `WuwaTappo FullAtlas Mac.app`。如系统拦截，请在确认来源后到「系统设置 → 隐私与安全性」选择「仍要打开」，无需关闭系统安全保护。
2. 首次启动可选「仅本次会话」或「记住登录」。前者将登录信息保存在内存，后者使用 macOS 钥匙串。
3. 要响应全局键鼠输入，请在「隐私与安全性 → 输入监控」中授权应用，并按系统提示重启。
4. 在设置中切换「本地全图鉴」，通过「挂机与统计」打开助手面板。首次使用请先验收普通登录和图鉴显示，再启用自动任务。

更新时退出旧版，再覆盖同名应用。若更新后输入失效，请检查输入监控条目并重新授权。此整合版使用独立应用标识，不会自动迁移原 Mac 项目的钥匙串和用户数据。

本项目的 1.2.1 与 1.2.2-alpha.1 使用相同应用标识和数据目录，试用前请退出另一个副本，并备份 `~/Library/Application Support/dev.w33d.wuwatappo.fullatlas.mac/`。实验版目前仅提供 Apple Silicon 构建。

目前未实现 Mac 自动安装更新。请使用本项目的 Mac 包；官方 Windows EXE 和 FullAtlas Windows 更新 ZIP 不能用于此应用。

## 从源码构建

需要 Xcode Command Line Tools、Node.js 24、[rustup](https://rustup.rs/) 和 7-Zip。Rust 版本固定在 `rust-toolchain.toml`（1.97.1），构建脚本还会使用 Python 3。

```bash
xcode-select --install
brew install node@24 sevenzip
# Homebrew 当前提供 rustup 管理器，不再提供 rustup-init。
brew install rustup
echo 'export PATH="$(brew --prefix rustup)/bin:$PATH"' >> ~/.zshrc
export PATH="$(brew --prefix rustup)/bin:$PATH"
rustup toolchain install 1.97.1 --profile minimal
rustup default 1.97.1

# 在源码根目录执行：
npm ci
npm run setup
npm test
npm run test:fullatlas
npm run test:rust
npm run build
npm run package
```

`setup` 下载 `upstream-cn.json` 锁定的官方安装包，核对大小和 SHA-256 后静态提取前端；整个过程不运行 Windows 程序。若已有对应官方原包，可用 `npm run assets:sync -- --installer /绝对路径/安装包.exe`，然后执行 `npm run icons` 和 `npm run prepare:frontend`。

构建应用位于 `src-tauri/target/release/bundle/macos/`，ZIP / DMG 位于 `dist/`。官方解包资源、依赖、安装包和用户数据不提交到源码仓库。清洁检出需要先执行 `setup`，部分测试需要已准备的前端。

## 如何跟进官方更新

官方客户端程序、公开图鉴数据、FullAtlas 功能代码分别维护：

- `npm run upstream:check` 只检查官方客户端版本；`npm run upstream:update` 会下载候选版本并修改官方资源锁，需要在适配分支执行。
- `npm run official:update` 是本地一键编排入口：默认只检测；`npm run official:update -- --apply` 才会下载并校验官方安装包、静态提取、注入 FullAtlas、运行测试、构建和打包 ZIP / DMG。失败会恢复更新前的资源锁和前端；未知前端结构会被版本门禁拦截。
- 应用内的「更新本地图鉴」刷新目录数据，不升级程序或接口适配器。
- `.github/workflows/sync-upstream.yml` 每日 **10:17（北京时间）** 检查国服更新。经静态提取、接口差异、测试、构建与打包验证后创建更新 PR；不兼容候选保持草稿，不自动合并。
- FullAtlas 集成器同时核对官方版本和安装包摘要。未知版本不会只靠修改版本号进入正式构建。
- CI 只构建国服整合版。版本标签触发的 Release 工作流只生成**草稿预发布**，需要维护者验收后手动发布。

在你的仓库启用 Actions 后这些工作流才会运行。定时同步需要在仓库设置中允许 Actions 创建 Pull Request，首次发布步骤见 [GitHub 发布指南](docs/PUBLISHING.md)。[官方更新流水线](docs/OFFICIAL_UPDATE_PIPELINE.md) 和 [来源与更新记录](docs/official-update-status-2026-10-30.md) 保留实现边界与核验信息。

这条流水线不能在已安装的 Mac 应用内部运行：官方提供的是 Windows EXE，转换需要 Node、7-Zip、Rust、Xcode 工具链和完整源码。桌宠可以检测并提示新 Mac Release，但下载、构建和替换应用必须由维护者或 GitHub Actions 完成。

## 隐私与许可

不在发行包中加入登录凭据、钥匙串、账号缓存、输入正文或运行日志。全局输入用于计数与动作反馈；登录与在线业务会连接对应官方服务。

macOS 项目与 FullAtlas 的 MIT 声明均保留；固定来源提交见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，FullAtlas 许可见 [licenses/FULLATLAS_LICENSE](licenses/FULLATLAS_LICENSE)。官方界面、角色、美术、音频、名称与商标保留各自权利，不因整合而转为 MIT 授权。使用官方服务仍需遵守相应规则。
