<#
  在桌面生成快捷方式：优先指向无控制台启动器 WuwaTappoLauncher.exe，
  没有启动器时回落到 app\start.cmd。

  用法： powershell -ExecutionPolicy Bypass -File tools\make-shortcut.ps1 [-Name "Wuwa Tappo 全图鉴版"]
  说明： 本机安全策略禁止 COM（WScript.Shell），因此用 pylnk3 直接写 .lnk
#>
param([string]$Name = 'Wuwa Tappo 全图鉴版')
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Py = Join-Path $Root '.venv\Scripts\python.exe'
$App = Join-Path $Root 'app'

if (-not (Test-Path -LiteralPath $Py)) { throw "缺少 .venv，先跑 tools\setup-env.ps1" }

$launcher = Join-Path $App 'WuwaTappoLauncher.exe'
$cmdEntry = Join-Path $App 'start.cmd'
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) "$Name.lnk"
$icon = Join-Path $App 'WuwaTappo.Local.exe'

if (Test-Path -LiteralPath $launcher) {
  $target = $launcher
  $extra = @('--window', 'normal')
  "入口: 无控制台启动器"
} elseif (Test-Path -LiteralPath $cmdEntry) {
  $target = $cmdEntry
  $extra = @('--window', 'minimized')
  "入口: start.cmd（建议跑 tools\build-launcher.ps1 换成无窗口启动器）"
} else {
  throw "app\ 里既没有 WuwaTappoLauncher.exe 也没有 start.cmd，先跑 tools\deploy.ps1"
}

& $Py (Join-Path $PSScriptRoot 'make_shortcut.py') `
  --out $out `
  --target $target `
  --workdir $App `
  --icon $icon `
  --description 'WuwaTappo 全图鉴版 1.3 - 适配官方 1.0.3' `
  @extra
"快捷方式: $out"
