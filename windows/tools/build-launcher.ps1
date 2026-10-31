<#
  编译无控制台启动器 app\WuwaTappoLauncher.exe

  用法： powershell -ExecutionPolicy Bypass -File tools\build-launcher.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Py = Join-Path $Root '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $Py)) { throw "缺少 .venv，先跑 tools\setup-env.ps1" }

& $Py -m PyInstaller --noconfirm --clean --onefile --noconsole --uac-admin `
  --name WuwaTappoLauncher `
  --distpath (Join-Path $Root 'build\launcher\dist') `
  --workpath (Join-Path $Root 'build\launcher\work') `
  --specpath (Join-Path $Root 'build\launcher') `
  (Join-Path $PSScriptRoot 'launcher.py')
if ($LASTEXITCODE -ne 0) { throw '启动器编译失败' }

$exe = Join-Path $Root 'build\launcher\dist\WuwaTappoLauncher.exe'
Copy-Item -LiteralPath $exe -Destination (Join-Path $Root 'app\WuwaTappoLauncher.exe') -Force
"已生成: app\WuwaTappoLauncher.exe ({0:N1} MB)" -f ((Get-Item -LiteralPath $exe).Length / 1MB)
