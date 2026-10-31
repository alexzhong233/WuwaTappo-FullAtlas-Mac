<#
  全量重建：解包官方 EXE -> 注入全图鉴 -> 冻结本地服务 -> 装配到 app\

  前置：
    1. tools\setup-env.ps1 已执行（.venv 就绪）
    2. 官方 1.0.3 主程序放到 build\base-103\WuwaTappo.official.exe
    3. assets\cache 已由 prepare_cache.py 拉好

  用法： powershell -ExecutionPolicy Bypass -File tools\build.ps1 [-Extract] [-NoDeploy] [-Base <目录>]
        -Extract   先重新解包官方 EXE（覆盖 build\base-103 的前端产物）
        -NoDeploy  只构建到 build\，不自动同步到 app\（更新流程用，先装配到中转目录再整体覆盖）
        -Base      指定官方主程序所在基底目录（默认为 build\base-103）
#>
param([switch]$Extract, [switch]$NoDeploy, [string]$Base)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Py = Join-Path $Root '.venv\Scripts\python.exe'
if (-not $Base) { $Base = Join-Path $Root 'build\base-103' }
$Official = Join-Path $Base 'WuwaTappo.official.exe'
$Patched = Join-Path $Root 'src'

if (-not (Test-Path -LiteralPath $Py)) { throw "缺少 .venv，先跑 tools\setup-env.ps1" }
if (-not (Test-Path -LiteralPath $Official)) { throw "缺少官方主程序：$Official" }


if ($Extract) {
  "== 1/4 解包官方 EXE =="
  $env:WUWA_EXTRACT_ROOT = $Base
  & $Py (Join-Path $Patched 'tools\extract_static.py') $Official
  if ($LASTEXITCODE -ne 0) { throw "解包失败" }
}

"== 2/4 注入全图鉴控制器 =="
$env:WUWA_BUILD_ROOT = (Join-Path $Root 'build')
$env:WUWA_EXTRACT_ROOT = $Base
# build_integration.py 从 build\current_base.txt 读基底路径，必须随 -Base 同步，
# 否则换了基底仍会指向旧目录（无 BOM，避免 read_text 读出 \ufeff）
[IO.File]::WriteAllText((Join-Path $Root 'build\current_base.txt'), $Base,
  (New-Object Text.UTF8Encoding($false)))
if (Test-Path -LiteralPath (Join-Path $Root 'build\frontend_v2')) {
  Remove-Item -LiteralPath (Join-Path $Root 'build\frontend_v2') -Recurse -Force
}
& $Py (Join-Path $Patched 'tools\build_integration.py')
if ($LASTEXITCODE -ne 0) { throw "注入失败" }

"== 3/4 冻结本地素材服务 =="
& $Py -m PyInstaller --noconfirm --clean --onedir --console --name LocalGalleryHost `
  --distpath (Join-Path $Root 'build\frozen') `
  --workpath (Join-Path $Root 'build\pyinstaller') `
  --specpath (Join-Path $Root 'build') `
  --paths (Join-Path $Patched 'src') `
  (Join-Path $Patched 'src\local_host.py')
if ($LASTEXITCODE -ne 0) { throw "冻结失败" }

if ($NoDeploy) {
  "== 4/4 跳过装配（-NoDeploy）=="
  "构建产物: build\WuwaTappo.Local.v2.exe 与 build\frozen\LocalGalleryHost"
  exit 0
}

"== 4/4 装配并同步到 app\ =="
& (Join-Path $PSScriptRoot 'deploy.ps1')
