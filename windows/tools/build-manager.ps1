<#
  编译更新管理器 app\WuwaTappoManager.exe

  说明：管理器需要 tkinter，项目 .venv(3.13) 不带 tk，因此用本机 miniconda 的
        Python 3.14（自带 tkinter 8.6 + PyInstaller）来打包。
        管理器自身不提权；「启动游戏」时才用 ShellExecute runas 拉起提权启动器。

  用法： powershell -ExecutionPolicy Bypass -File tools\build-manager.ps1
#>
param([string]$Python = 'D:\DevTools\miniconda3\python.exe')

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent

if (-not (Test-Path -LiteralPath $Python)) { throw "找不到打包用 Python：$Python" }
& $Python -c "import tkinter, PyInstaller; print('tk', tkinter.TkVersion, '| pyinstaller ok')"
if ($LASTEXITCODE -ne 0) { throw "该 Python 缺少 tkinter 或 PyInstaller：$Python" }

& $Python -m PyInstaller --noconfirm --clean --onefile --noconsole `
  --name WuwaTappoManager `
  --distpath (Join-Path $Root 'build\manager\dist') `
  --workpath (Join-Path $Root 'build\manager\work') `
  --specpath (Join-Path $Root 'build\manager') `
  (Join-Path $PSScriptRoot 'manager.py')
if ($LASTEXITCODE -ne 0) { throw '管理器编译失败' }

$exe = Join-Path $Root 'build\manager\dist\WuwaTappoManager.exe'
Copy-Item -LiteralPath $exe -Destination (Join-Path $Root 'app\WuwaTappoManager.exe') -Force
"已生成: app\WuwaTappoManager.exe ({0:N1} MB)" -f ((Get-Item -LiteralPath $exe).Length / 1MB)
