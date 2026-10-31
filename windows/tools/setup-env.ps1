<#
  创建项目独立的 Python 构建环境（.venv）并安装依赖

  用法： powershell -ExecutionPolicy Bypass -File tools\setup-env.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Venv = Join-Path $Root '.venv'

# 优先用托管 Python 3.13；PyInstaller 6.16 对 3.14 支持不稳
$candidates = @(
  'C:\Users\eatfo\.workbuddy\binaries\python\versions\3.13.12\python.exe',
  'C:\Users\eatfo\.workbuddy\binaries\python\versions\3.13.6\python.exe'
)
$Python = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $Python) {
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd) { $Python = $cmd.Source } else { throw '找不到 Python 3.13，请先安装或修改本脚本里的路径' }
}
"Python: $Python"
"版本: " + (& $Python --version 2>&1)

if (-not (Test-Path -LiteralPath (Join-Path $Venv 'Scripts\python.exe'))) {
  & $Python -m venv $Venv
  if ($LASTEXITCODE -ne 0) { throw '创建 venv 失败' }
}

$venvPy = Join-Path $Venv 'Scripts\python.exe'
& $venvPy -m pip install -q --disable-pip-version-check --upgrade pip
& $venvPy -m pip install -q --disable-pip-version-check -r (Join-Path $Root 'src\requirements-build.txt')
if ($LASTEXITCODE -ne 0) { throw '安装依赖失败' }

& $venvPy -c "import PyInstaller, pefile, brotli, jsbeautifier, psutil; print('依赖就绪 PyInstaller', PyInstaller.__version__)"
"环境就绪：$Venv"
