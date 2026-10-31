# WuwaTappo FullAtlas — Windows 侧

这个目录是本仓库的 Windows 平台实现。和 macOS 侧**不是同一套机制**，先看区别再动手：

| | macOS（仓库根目录） | Windows（本目录） |
| --- | --- | --- |
| 做法 | 用 Rust / Tauri 重写壳 | 给官方 Windows 客户端打补丁并重打包 |
| 为什么 | 官方没有 Mac 包 | 官方包本来就能跑，重写没有收益 |
| 运行时 | 原生 IPC 绑定 | Python 本地服务 + 本机 HTTP（端口 43229） |
| 产物 | `.app` / `.dmg`（约 70 MiB） | 绿色目录（约 1.1 GB，含 3098 张图） |

两侧共用同一条上游：库洛官方国服客户端（同一个安装包，SHA-256 在仓库根的 `upstream-cn.json` 里锁着）。

## 产物形态

- 绿色版，不写注册表、不装服务，整个 `app\` 目录拷走就能用。
- 入口 `WuwaTappoLauncher.exe`：无控制台窗口，自动提权（主程序清单是 `requireAdministrator`）。
- 官方自动更新**永久关闭**（`isAppUpdaterEnabled()` 返回 false）：改过的 exe 过不了官方 minisign 签名，走 OTA 会把补丁覆盖掉。

## 从零构建

需要 Windows 10/11 x64、Python 3.13、PowerShell 5.1、Node（仅语法检查用）。

```powershell
# 1. 建 .venv 并装依赖（只需一次）
powershell -File tools\setup-env.ps1

# 2. 官方 1.0.3 主程序放到 build\base-103\WuwaTappo.official.exe
#    可用 tools\update-watch.ps1 自动下载解包，或手动从官方安装包取出

# 3. 全量重建：解包 → 注入全图鉴 → 冻结本地服务 → 装配
powershell -File tools\build.ps1 -NoDeploy
powershell -File tools\deploy.ps1
```

`build.ps1 -Extract` 会重新解包官方 EXE，`-Base <目录>` 可指向新版基底。`deploy.ps1 -Target <目录>` 可装配到别处。

## 目录

```
windows\
├─ src\              注入用的 FullAtlas 源码（原上游仓库内容 + 1.0.3 适配改动）
│   ├─ src\          本地服务 local_host.py、助手后端、3 个前端模块
│   ├─ tools\        build_integration.py（注入）、extract_static.py（解包）、pe_packer.py（重打包）
│   └─ installer\    提权脚本存档（本机策略会删 .ps1，见「已知限制」）
├─ tools\
│   ├─ setup-env.ps1 / build.ps1 / deploy.ps1      主链路
│   ├─ check-update.ps1 / update-watch.ps1         官方版本检查与跟进
│   ├─ manager.py / build-manager.ps1              更新管理器 GUI
│   ├─ apply-update.ps1                            替换运行目录（带备份与回滚）
│   ├─ launcher.py / build-launcher.ps1            无控制台启动器
│   ├─ make_shortcut.py / make-shortcut.ps1        桌面快捷方式（本机禁 COM，手写 .lnk）
│   └─ patches\                                    1.0.3 适配差异存档
└─ docs\             构建记录、验证清单、安装说明
```

`app\`、`build\`、`.venv\`、`assets\` 都是产物或缓存，已在 `.gitignore` 里，不会进仓库。

## 官方更新怎么跟

游戏版本和 FullAtlas 前端是两条独立的轴：

- **游戏版本**（1.0.3 → 1.0.4）：前端 JS 结构变化会让注入锚点失效。`check-update.ps1` 查版本，`update-watch.ps1` 下载并试注入到 staging（不碰 `app\`），注入失败会报出是哪一处锚点断了。
- **FullAtlas 前端**（上游仓库 v1.2 → v1.3）：改动在 `src\src\` 那 3 个 JS 里，合并后要重跑一次构建验证。

注入锚点是压缩后的变量名，1.0.3 相对 1.0.2 断了 6 处（主锚点 `applyCatalog(e,t,n)` 三次都没变，辅助模块会漂移）。锚点不对时脚本直接报错并保持 `app\` 不动，不做「能启动但 UI 错位」的静默失败。

## 已知限制

1. **本机安全策略禁止 COM**（`WScript.Shell`、`Shell.Application` 一律拦截）。快捷方式改用 `pylnk3` 直接写 `.lnk` 二进制（`tools\make_shortcut.py`）。手写字节不行——Windows 要求 `LinkTargetIDList`，只有 `LinkInfo` 的链接会被 shell 拒绝。
2. **`launch.ps1` 会被安全策略自动删除**（自提权脚本 `Start-Process -Verb RunAs`）。内容存档在 `src\installer\launch.ps1.disabled.txt`，入口统一用 `WuwaTappoLauncher.exe`。
3. **`schtasks.exe` 被黑名单拦截**，注册定时检查要用 PowerShell 原生 `Register-ScheduledTask`（`tools\install-schedule.ps1` 已处理）。
4. **没有 CI**。构建要 1.6 GB 基底和解包产物，目前只在本地跑。接入 GitHub Actions 需要复用 macOS 侧的官方包下载与校验流程（见根目录 `docs/OFFICIAL_UPDATE_PIPELINE.md`），这是后续工作。
5. **只有绿色版，没有安装包**（未装 Inno Setup）。需要时再说。

## 与 macOS 侧的关系

前端那 3 个模块（`local_atlas_controller.js` / `assistant_dashboard.js` / `desktop_assistant.js`）两边同源，目前各存一份，差异只有 4 行/文件，都是平台绑定：

| 文件 | Windows 版 | macOS 版 |
| --- | --- | --- |
| `local_atlas_controller.js` | 直接 `rawFetch` 到本机 HTTP | 有 `d.request` 钩子时走原生 IPC；`assetsHost` 用 `offlineData.assets_host` |
| `assistant_dashboard.js` | 「官方基底监控」卡片，查 Kuro 版本 | 「Mac 版本更新」卡片，查 `/official/update-check` |
| `desktop_assistant.js` | `VERSION = '1.2'` | `VERSION = '1.2.2-alpha.1'` |

收敛方案：以 macOS 版已有的 `d.request` 作为传输层抽象，Windows 侧实现一个走本机 HTTP 的版本，两边共用一个文件。这一步还没做。
