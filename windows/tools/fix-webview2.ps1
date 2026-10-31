<#
  修复 "找不到 WebView2" 启动失败。

  背景：pe_packer.py 注入的入口 stub 会无条件设置
    WEBVIEW2_BROWSER_EXECUTABLE_FOLDER=<应用目录>\runtime
    WEBVIEW2_USER_DATA_FOLDER=<应用目录>\profile
  一旦 <应用目录>\runtime 不存在（-NoRuntime 构建的 CI / 发布包），
  WebView2 加载器就找不到指定运行时，且不会回退系统运行时，直接报错退出。

  本脚本把系统已装的 WebView2 以目录联接（junction）挂到 <应用目录>\runtime，
  零拷贝、不占磁盘；联接不可用时回退为 robocopy 实拷贝。

  用法：
    powershell -ExecutionPolicy Bypass -File tools\fix-webview2.ps1
    powershell -ExecutionPolicy Bypass -File tools\fix-webview2.ps1 -Target "C:\path\to\app" -Copy
#>
param(
  [string]$Target,
  [switch]$Copy
)
$ErrorActionPreference = 'Stop'

if (-not $Target) {
  $Target = Join-Path (Split-Path $PSScriptRoot -Parent) 'app'
}
if (-not (Test-Path -LiteralPath (Join-Path $Target 'WuwaTappo.Local.exe'))) {
  throw "目标目录里没有 WuwaTappo.Local.exe：$Target"
}

# 取系统已装的最新一份 WebView2
$wv = @(
  'C:\Program Files (x86)\Microsoft\EdgeWebView\Application',
  'C:\Program Files\Microsoft\EdgeWebView\Application'
) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
  Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue
} | Where-Object {
  Test-Path -LiteralPath (Join-Path $_.FullName 'msedgewebview2.exe')
} | Sort-Object {
  try { [version]($_.Name -replace '[^0-9.]', '') } catch { [version]'0.0' }
} | Select-Object -Last 1

if (-not $wv) {
  throw '系统未安装 WebView2 运行时。请先安装 Evergreen 运行时：https://go.microsoft.com/fwlink/p/?LinkId=2124703'
}
Write-Host "系统 WebView2: $($wv.FullName)"

$runtime = Join-Path $Target 'runtime'
if (Test-Path -LiteralPath $runtime) {
  $existing = Get-Item -LiteralPath $runtime -Force
  if ((Test-Path -LiteralPath (Join-Path $runtime 'msedgewebview2.exe')) -and
      ($existing.LinkType -or -not $Copy)) {
    Write-Host "runtime 已就绪（$($existing.LinkType ?? '实目录')），无需处理。"
    return
  }
  Write-Host 'runtime 存在但无效或需实拷贝，重建中…'
  Remove-Item -LiteralPath $runtime -Recurse -Force
}

$linked = $false
if (-not $Copy) {
  try {
    New-Item -ItemType Junction -Path $runtime -Target $wv.FullName -ErrorAction Stop | Out-Null
    $linked = $true
  } catch {
    Write-Warning "目录联接失败（$($_.Exception.Message)），改为实拷贝"
  }
}

if (-not $linked) {
  robocopy $wv.FullName $runtime /E /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy 失败，退出码 $LASTEXITCODE" }
}

if (-not (Test-Path -LiteralPath (Join-Path $runtime 'msedgewebview2.exe'))) {
  throw 'runtime 里仍缺少 msedgewebview2.exe'
}
$mode = if ($linked) { 'junction（零拷贝）' } else { '实拷贝' }
Write-Host "完成：$runtime  ←  $($wv.Name)  模式：$mode" -ForegroundColor Green
Write-Host '现在双击 WuwaTappoLauncher.exe 或 启动.cmd 应该能正常打开。'
