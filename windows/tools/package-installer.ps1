<#
  把装配好的 app\ 打成 Windows 安装包（NSIS）

  产物： dist\WuwaTappo-Full-CN-Community-Windows-x64-<version>.exe
         dist\...-Windows-x64-<version>.exe.sha256

  按用户安装到 %LOCALAPPDATA%\Programs\<产品名>，不需要管理员权限；
  装完桌面与开始菜单各有快捷方式，双击即用，控制面板里可卸载。

  版本号取自仓库根的 package.json（与 macOS 产物保持一致）。

  用法：
    powershell -File windows\tools\package-installer.ps1
    powershell -File windows\tools\package-installer.ps1 -Region global
#>
param(
  [string]$Source,
  [string]$OutDir,
  [switch]$NoRuntime,
  [switch]$KeepStaging,
  [ValidateSet('cn', 'global')][string]$Region
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$RepoRoot = Split-Path $Root -Parent
. (Join-Path $PSScriptRoot 'region.ps1')
. (Join-Path $PSScriptRoot 'payload.ps1')
$R = Get-RegionProfile -Root $Root -Region $Region

# 不依赖 Get-FileHash：从 pwsh 7 环境启动 PS 5.1 时该 cmdlet 可能加载不到
function Get-Sha256Hex([string]$path) {
  $algorithm = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($path)
  try { $bytes = $algorithm.ComputeHash($stream) } finally { $stream.Dispose(); $algorithm.Dispose() }
  return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Find-Makensis {
  $candidates = @()
  $command = Get-Command makensis -ErrorAction SilentlyContinue
  if ($command) { $candidates += $command.Source }
  $programFilesX86 = ${env:ProgramFiles(x86)}
  if ($programFilesX86) { $candidates += (Join-Path $programFilesX86 'NSIS\makensis.exe') }
  if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'NSIS\makensis.exe') }
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return $null
}

if (-not $Source) { $Source = $R.AppDir }
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist' }

$version = (Get-Content -LiteralPath (Join-Path $RepoRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
$name = "$($R.ArtifactPrefix)-Windows-x64-$version"
$exe = Join-Path $OutDir "$name.exe"

if (-not (Test-Path -LiteralPath $Source)) { throw "找不到待打包目录：$Source（先跑 build.ps1 / deploy.ps1）" }
if (-not (Test-Path -LiteralPath (Join-Path $Source 'WuwaTappo.Local.exe'))) { throw "目录里没有 WuwaTappo.Local.exe，可能是空部署：$Source" }

$makensis = Find-Makensis
if (-not $makensis) {
  throw "找不到 makensis：先装 NSIS（choco install nsis -y），或把 makensis.exe 加进 PATH。"
}

# 入口：优先无控制台启动器；没有就退回 start.cmd（会带一个控制台窗口）
$entry = if (Test-Path -LiteralPath (Join-Path $Source 'WuwaTappoLauncher.exe')) { 'WuwaTappoLauncher.exe' } else { 'start.cmd' }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }

$staging = Join-Path $R.WorkDir 'installer-staging'
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
$payload = Join-Path $staging 'payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null

Write-Host "== 收集文件（入口：$entry）=="
$files = Get-WuwaPayloadFiles -Source $Source -NoRuntime:$NoRuntime
foreach ($f in $files) {
  $rel = $f.FullName.Substring($Source.Length).TrimStart('\')
  $dest = Join-Path $payload $rel
  New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
  Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
}
Write-Host ("共 {0} 个文件，{1:N1} MB" -f $files.Count, (($files | Measure-Object -Property Length -Sum).Sum / 1MB))

# 图标沿用官方客户端里提取出来的那份；没有就不设，NSIS 用默认图标
$icon = Get-ChildItem -LiteralPath (Join-Path $R.WorkDir 'official') -Recurse -Filter 'icon_32512.ico' -ErrorAction SilentlyContinue | Select-Object -First 1
$iconLine = if ($icon) { 'Icon "' + $icon.FullName + '"' } else { '; 未找到官方图标，使用 NSIS 默认图标' }

$nsi = Join-Path $staging 'installer.nsi'
$template = @'
Unicode true
SetCompressor /SOLID lzma
Name "{{PRODUCT}}"
OutFile "{{PKG}}"
InstallDir "$LOCALAPPDATA\Programs\{{PRODUCT}}"
InstallDirRegKey HKCU "Software\{{PRODUCT}}" "InstallDir"
RequestExecutionLevel user
ShowInstDetails show
ShowUninstDetails show
{{ICON}}

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "Install"
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "{{PAYLOAD}}\*.*"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  CreateDirectory "$SMPROGRAMS\{{PRODUCT}}"
  CreateShortCut "$SMPROGRAMS\{{PRODUCT}}\{{PRODUCT}}.lnk" "$INSTDIR\{{ENTRY}}"
  CreateShortCut "$DESKTOP\{{PRODUCT}}.lnk" "$INSTDIR\{{ENTRY}}"

  WriteRegStr HKCU "Software\{{PRODUCT}}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\{{PRODUCT}}" "DisplayName" "{{PRODUCT}}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\{{PRODUCT}}" "DisplayVersion" "{{VERSION}}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\{{PRODUCT}}" "DisplayIcon" "$INSTDIR\{{ENTRY}}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\{{PRODUCT}}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\{{PRODUCT}}" "UninstallString" "$INSTDIR\uninstall.exe"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\{{PRODUCT}}" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\{{PRODUCT}}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$DESKTOP\{{PRODUCT}}.lnk"
  Delete "$SMPROGRAMS\{{PRODUCT}}\{{PRODUCT}}.lnk"
  RMDir "$SMPROGRAMS\{{PRODUCT}}"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\{{PRODUCT}}"
  DeleteRegKey HKCU "Software\{{PRODUCT}}"
SectionEnd
'@

$script = $template
$script = $script.Replace('{{PRODUCT}}', $R.ProductName)
$script = $script.Replace('{{VERSION}}', $version)
$script = $script.Replace('{{ENTRY}}', $entry)
$script = $script.Replace('{{PKG}}', $exe)
$script = $script.Replace('{{PAYLOAD}}', $payload)
$script = $script.Replace('{{ICON}}', $iconLine)
[IO.File]::WriteAllText($nsi, $script, (New-Object Text.UTF8Encoding($true)))

Write-Host "== 编译安装包（makensis）=="
& $makensis /V2 $nsi
if ($LASTEXITCODE -ne 0) { throw "makensis 失败，退出码 $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $exe)) { throw "没有生成安装包：$exe" }

if (-not $KeepStaging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }

$exeSize = (Get-Item -LiteralPath $exe).Length
$sha = Get-Sha256Hex $exe
"$sha  $name.exe" | Set-Content -LiteralPath "$exe.sha256" -Encoding ASCII

''
'打包完成'
"  文件: $exe"
"  大小: {0:N1} MB" -f ($exeSize / 1MB)
"  sha256: $sha"
