<#
  编译无控制台启动器 <工作目录>\launcher\dist\WuwaTappoLauncher.exe

  build.ps1 会自动调用；单独用也行：
    powershell -ExecutionPolicy Bypass -File tools\build-launcher.ps1
    powershell -ExecutionPolicy Bypass -File tools\build-launcher.ps1 -Region global

  为什么必须存在：安装包的快捷方式指向它。没有它就只能退到 start.cmd，
  双击会先弹一个控制台窗口、图标也是 cmd 的——这是发行包最显眼的体检项，
  所以 build.ps1 里缺了就构建，package-installer.ps1 缺了就直接报错。

  图标取自官方客户端解包出来的 icon_32512.ico，找不到就用 PyInstaller 默认图标。

  注意：不再用 --uac-admin。启动器只做「拉起本地服务 + 拉起主程序」，
  不需要管理员权限；带上它会让每次双击都先弹一次 UAC 确认框。
#>
param(
  [string]$Icon,
  [ValidateSet('cn', 'global')][string]$Region
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'region.ps1')
$R = Get-RegionProfile -Root $Root -Region $Region

$Py = Join-Path $Root '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $Py)) { throw "缺少 .venv，先跑 tools\setup-env.ps1" }

if (-not $Icon) {
  $candidate = Get-ChildItem -LiteralPath (Join-Path $R.WorkDir 'official') -Recurse -Filter 'icon_32512.ico' -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($candidate) { $Icon = $candidate.FullName }
}

$dist = Join-Path $R.WorkDir 'launcher\dist'
$pyArgs = @(
  '-m', 'PyInstaller', '--noconfirm', '--clean', '--onefile', '--noconsole',
  '--name', 'WuwaTappoLauncher',
  '--distpath', $dist,
  '--workpath', (Join-Path $R.WorkDir 'launcher\work'),
  '--specpath', (Join-Path $R.WorkDir 'launcher')
)
if ($Icon) { $pyArgs += @('--icon', $Icon) }
$pyArgs += (Join-Path $PSScriptRoot 'launcher.py')

& $Py @pyArgs
if ($LASTEXITCODE -ne 0) { throw '启动器编译失败' }

$exe = Join-Path $dist 'WuwaTappoLauncher.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "没有生成启动器：$exe" }

# 单独运行本脚本时顺手更新 app\；走 build.ps1 的话由 deploy.ps1 装配
$app = Join-Path $Root 'app'
if (Test-Path -LiteralPath $app) {
  Copy-Item -LiteralPath $exe -Destination (Join-Path $app 'WuwaTappoLauncher.exe') -Force
}
"已生成: $exe ({0:N1} MB)" -f ((Get-Item -LiteralPath $exe).Length / 1MB)
