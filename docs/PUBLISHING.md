# 手动发布到 GitHub

## 创建仓库并上传源码

在 GitHub 创建空仓库，建议名称 `WuwaTappo-FullAtlas-Mac`。不要勾选自动生成 README、License 或 .gitignore，本地已包含这些文件。复制 GitHub 显示的仓库 URL，并在项目根目录执行：

```bash
git remote add origin <你的仓库URL>
git push -u origin main
git push -u origin official-1.0.3
```

如果已经设置 `origin`，先用 `git remote -v` 检查，不要重复添加。仓库默认分支设为 `main`；`official-1.0.3` 是实验适配分支，不能与稳定基底混淆。

`release-assets/` 存放之前构建的 1.2.1 安装包，仅供本地使用，已加入忽略规则。`dist/`、官方 EXE、解包前端、node_modules、Rust target、缓存和日志均不应推送到 Git 历史。安装包用 GitHub Release 附件分发。

## 启用 CI 和官方更新检查

1. 在 Actions 页面启用工作流。
2. 如使用官方更新 PR 自动化，到 Settings → Actions → General 开启 **Allow GitHub Actions to create and approve pull requests**；只使用普通构建无需此设置。
3. 手动运行 CI，确认从空缓存也能准备前端、测试并打包。
4. 每日检查只发现并验证候选更新，不自动合并或发布。

构建工作流的下载镜像指向当前仓库自己的 `upstream-resources` Release。没有镜像时首先从官方源下载；不要复制别人的凭据或私有下载链接。

## 发布 1.2.1 预览版

先在本机验收登录、仅本次会话、输入权限、图鉴开关、助手开关以及普通联机；自动测试不能替代这些检查。确认准备发布的源码位于 `main` 后：

```bash
git switch main
git tag v1.2.1
git push origin v1.2.1
```

Release 工作流构建 ZIP / DMG 后创建 **Draft / Pre-release**，不会直接公开。到 Releases 核对版本、附件、说明后再手动 Publish。

如果不使用 Actions，也可在 GitHub 手动创建 `v1.2.1` 草稿预发布，附上 `release-assets/` 内的两个文件，并使用 [发布说明](RELEASE_NOTES_1.2.1.md)。这两个本地产物来自迁移前的 1.0.2 整合构建，不是 1.0.3 分支产物；源代码后续若有行为变更，必须重新构建附件。

## 后续版本

新版本需要同步 `package.json`、`package-lock.json`、Cargo、Tauri 配置与助手显示版本，并重新完成测试和实机验收。官方版本锁记录的是官方 Windows 资源版本，与整合版发布版本独立。对未知官方版本不要绕过版本 / SHA-256 门禁。
