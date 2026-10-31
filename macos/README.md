# WuwaTappo Full Community — macOS 侧

这个目录是本仓库的 macOS 平台实现。对侧是 [`windows/`](../windows/README.md)，两边机制不同：

| | macOS（本目录） | Windows（[`windows/`](../windows/README.md)） |
| --- | --- | --- |
| 做法 | Rust / Tauri 原生壳重写 | 给官方客户端打补丁并重打包 PE |
| 为什么 | 官方没有 Mac 包 | 官方包本来能跑，重写没有收益 |
| 运行时 | 原生 IPC 绑定 | Python 本地服务 + 本机 HTTP（端口 43229） |
| 工具链 | Node + Rust + Xcode CLT + 7-Zip | PowerShell + Python + PyInstaller |
| 产物 | `.app` / `.dmg`（约 70 MiB） | 绿色目录（约 1.1 GB） |

两侧共用同一条上游：库洛官方国服客户端，安装包与 SHA-256 锁在本目录的 `upstream-cn.json`。

## 目录

```text
macos/
├─ src-tauri/            Rust 后端与 Tauri 配置（tauri.conf.json、tauri.global.conf.json）
├─ scripts/              构建链：前端准备、注入、打包、上游同步与校验（*.mjs / *.js / package-macos.sh）
├─ tests/                node --test 套件；契约、前端适配、打包、平台一致性、仓库结构
├─ tools/                FullAtlas 集成器（Python）与前端结构检查器
├─ fullatlas-source/     共用前端模块的 Mac 侧副本（与 windows/src 的差异锁在 4 行内）
├─ docs/                 官方版本适配记录、更新流水线、发布步骤、Release Notes
├─ upstream-cn.json      国服官方客户端锁定版本、安装包直链与 SHA-256
├─ upstream-global.json  国际服同上（代码保留，不作为发行目标）
└─ rust-toolchain.toml   Rust 版本固定（1.97.1，CI 与本地共用）
```

`build/`、`frontend/`、`frontend-global/`、`src-tauri/target/`、`src-tauri/icons*/`、`.work/` 都是本目录下的产物或缓存，已在仓库根的 `.gitignore` 里。

## 命令入口

**npm 入口在仓库根**（`package.json` 只有一份，发版号也是它），脚本内部再指到本目录：

```bash
npm ci                 # 仓库根；依赖装在仓库根 node_modules
npm run setup          # 同步官方基底 + 生成图标 + 准备前端
npm test               # node --test macos/tests/*.test.mjs
npm run test:fullatlas # 3 个共用前端模块的适配测试
npm run test:rust      # cargo test（仅 macOS）
npm run build          # Tauri 构建 → macos/src-tauri/target/release/bundle/macos/
npm run package        # 校验签名与内嵌资源，产出 ZIP / DMG 到仓库根 dist/
npm run build:mac -- --package   # 上面两步合一，走跨平台分派器
```

产物统一落在**仓库根的 `dist/`**，与 Windows 侧同一个交付目录；临时日志与中间状态落在本目录的 `.work/`，不进仓库。

## 与 Windows 侧怎么分工

- **共用**：`fullatlas-source/*.js` 三个前端模块与 `windows/src/src` 下的同名文件同源，各只差 4 行（品牌文案、更新监控卡、`VERSION`、`assetsHost`/`request` 取值）。不并成一份，是因为 `windows/src` 是上游完整快照，抽公共件会让上游 diff 失去基线；差异规模由 `tests/platform-parity.test.mjs` 锁住。
- **不共用**：运行时、构建层、注入器范式完全不同（Rust/Tauri vs Python/PE 重打包），硬并只会造出一个到处 `if (platform === ...)` 的缝合怪。

## 三条刻意不动的约定

1. **Bundle identifier 保持 `dev.w33d.wuwatappo.fullatlas.mac`**。改了等于换一个应用：已有用户的 `~/Library/Application Support/` 与钥匙串全部作废。改名只动显示名与产物名。
2. **`fullatlas-source/` 与 `tools/`、`fullatlas-*` 模块名保持上游命名**，那是上游项目和它自己的模块结构，动了就断链。
3. **`src-tauri/src/*.rs` 里发往官方 CDN 的 User-Agent 常量保留旧名**：纯网络标识，与数据目录无关，改它没有收益。

## 搬目录时最容易踩的坑

`src-tauri/tauri.conf.json` 的 `bundle.resources` 会往父目录取文件（`../../LICENSE`、`../../THIRD_PARTY_NOTICES.md`、`../../licenses/FULLATLAS_LICENSE`、`../build/fullatlas-catalog.json`）。这类路径写错，本地构建不报错，只有 macOS 打包或运行期取资源时才炸——所以 `tests/package-macos.test.mjs` 会逐个核对已入库资源是否真实存在。

同理，`regions.mjs` 里的 `frontendDir`、`preparedDir`、`iconsDir`、`tauriConfig` 都是相对本目录的路径；`package-macos.sh` 还会强校验 `tauri.conf.json` 的 `productName` 与 `regions.mjs` 完全一致（国际服配置漏改会直接断构建）。
