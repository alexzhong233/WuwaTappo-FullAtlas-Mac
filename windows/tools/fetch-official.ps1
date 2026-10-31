<#
  获取官方 Windows 主程序基底（只解包，不执行安装器）

  用途：让 CI 与本地都能拿到 build\official\<版本>\base\WuwaTappo.official.exe，
        再交给 build.ps1 -Base。

  重要：官方安装包一律用 7-Zip 解包，**从不执行**。
        执行安装器会真的把客户端装进系统、启动进程、写 LOCALAPPDATA 缓存，
        这不是构建该做的事。

  版本来源优先级：
    1. -OfficialExe 直接指定已解出的 WuwaTappo.exe（最省事，推荐本地用）
    2. -Installer   指定本地安装包（用 7z 解）
    3. -Version     指定版本；与官方最新版一致时走官方清单
    4. 默认读 windows\upstream-win.json 的 client_version（-Latest 改为跟最新）

  用法：
    powershell -File windows\tools\fetch-official.ps1
    powershell -File windows\tools\fetch-official.ps1 -OfficialExe D:\path\WuwaTappo.exe
    powershell -File windows\tools\fetch-official.ps1 -Installer D:\path\setup.exe
    powershell -File windows\tools\fetch-official.ps1 -Latest
#>
param(
  [string]$Version,
  [string]$Installer,
  [string]$OfficialExe,
  [switch]$Latest,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$AssetsHost = 'https://mc-wuwatappo.kurogames-global.com'
$LockFile = Join-Path $Root 'upstream-win.json'

function Get-Json([string]$url) {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
  $wc = New-Object System.Net.WebClient
  $wc.Proxy = $null
  $wc.Encoding = [Text.Encoding]::UTF8
  $wc.Headers.Add('User-Agent', 'WuwaTappo-FullAtlas-Fetch/1.0')
  try { return ($wc.DownloadString($url) | ConvertFrom-Json) } finally { $wc.Dispose() }
}

function Get-RemoteManifest {
  $hostJson = Get-Json "$AssetsHost/app/json-host/latest_host.json"
  if (-not $hostJson.url) { throw 'latest_host.json 未返回 url 字段' }
  # 必须用清单返回的带 ?t= 的地址，直连 version-json 会命中 CDN 缓存拿到旧版本
  return Get-Json ([string]$hostJson.url)
}

function Find-SevenZip {
  foreach ($p in @(
      'C:\Program Files\7-Zip\7z.exe',
      'C:\Program Files (x86)\7-Zip\7z.exe'
    )) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  $cmd = Get-Command 7z -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# 不依赖 Get-FileHash：从 pwsh 7 环境启动 PS 5.1 时该 cmdlet 可能加载不到
function Get-Sha256Hex([string]$path) {
  $algorithm = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($path)
  try { $bytes = $algorithm.ComputeHash($stream) } finally { $stream.Dispose(); $algorithm.Dispose() }
  return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# 仓库里的 JSON 是无 BOM UTF-8，PS 5.1 默认按 GBK 读会把中文读坏，必须显式 -Encoding UTF8
$lock = if (Test-Path -LiteralPath $LockFile) { Get-Content -LiteralPath $LockFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$lockedVersion = if ($lock) { [string]$lock.client_version } else { '' }

if ($OfficialExe) {
  if (-not (Test-Path -LiteralPath $OfficialExe)) { throw "指定的主程序不存在: $OfficialExe" }
  $target = if ($Version) { $Version } elseif ($lockedVersion) { $lockedVersion } else { 'custom' }
  $work = Join-Path $Root "build\official\$target"
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  "== 1/2 使用已有主程序 =="
  "来源: $((Resolve-Path -LiteralPath $OfficialExe).Path)"
  $sourceExe = (Resolve-Path -LiteralPath $OfficialExe).Path
} else {
  if (-not $Installer) {
    "== 1/4 解析目标版本 =="
    $manifest = $null
    if ($Latest -or $Version -or (-not $lockedVersion)) { $manifest = Get-RemoteManifest }

    if ($Version) { $target = $Version }
    elseif ($Latest) { $target = [string]$manifest.version }
    else { $target = $lockedVersion }

    "目标版本: $target"
    if ($lockedVersion) { "锁定版本: $lockedVersion" }

    $url = $null
    if ($manifest -and [string]$manifest.version -eq $target) {
      $url = [string]$manifest.platforms.'windows-x86_64'.url
      '来源    : 官方清单（最新版）'
    }
    if (-not $url -and $lock -and [string]$lock.client_version -eq $target -and $lock.installer_url) {
      $url = [string]$lock.installer_url
      '来源    : upstream-win.json 锁定直链'
    }
    if (-not $url) {
      throw "找不到 $target 的下载地址。请用 -Installer 指定本地安装包，或 -Latest 取官方最新版。"
    }
    "地址    : $url"

    $work = Join-Path $Root "build\official\$target"
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $setup = Join-Path $work (Split-Path $url -Leaf)
    if ((Test-Path -LiteralPath $setup) -and -not $Force) {
      "已存在，跳过下载: $setup"
    } else {
      "== 2/4 下载安装包 =="
      $dl = New-Object System.Net.WebClient
      $dl.Proxy = $null
      $dl.Headers.Add('User-Agent', 'WuwaTappo-FullAtlas-Fetch/1.0')
      try { $dl.DownloadFile($url, $setup) } finally { $dl.Dispose() }
      "下载完成: {0:N1} MB" -f ((Get-Item -LiteralPath $setup).Length / 1MB)
    }
  } else {
    if (-not (Test-Path -LiteralPath $Installer)) { throw "安装包不存在: $Installer" }
    $target = if ($Version) { $Version } elseif ($lockedVersion) { $lockedVersion } else { 'custom' }
    $setup = (Resolve-Path -LiteralPath $Installer).Path
    $work = Join-Path $Root "build\official\$target"
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    "使用指定安装包: $setup"
  }
  $sourceExe = $null
}

$base = Join-Path $work 'base'
$official = Join-Path $base 'WuwaTappo.official.exe'

if ((Test-Path -LiteralPath $official) -and -not $Force) {
  '已存在基底，跳过解包（要重解加 -Force）'
} else {
  if (-not $sourceExe) {
    "== 3/4 解包（7-Zip，不执行安装器）=="
    $sevenZip = Find-SevenZip
    if (-not $sevenZip) {
      throw @"
找不到 7-Zip。解包需要它，且本脚本不会执行官方安装器。
  安装： winget install 7zip.7zip
  或者： 手动从安装包取出 WuwaTappo.exe 后用 -OfficialExe 直接指定
"@
    }
    "7-Zip: $sevenZip"
    $extractDir = Join-Path $work 'app'
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    & $sevenZip x $setup "-o$extractDir" -y -bso0 -bsp0
    if ($LASTEXITCODE -ne 0) { throw "7z 解包失败，退出码 $LASTEXITCODE" }
    $inner = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'WuwaTappo.exe' -ErrorAction SilentlyContinue |
      Where-Object { $_.Length -gt 20MB } |
      Sort-Object Length -Descending | Select-Object -First 1
    if (-not $inner) {
      throw "解包后未找到 WuwaTappo.exe。目录内容：$((Get-ChildItem $extractDir -Recurse -File | Select-Object -First 10 -ExpandProperty Name) -join ', ')"
    }
    "内层主程序: $($inner.FullName)  ({0:N1} MB)" -f ($inner.Length / 1MB)
    $sourceExe = $inner.FullName
  }
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
  New-Item -ItemType Directory -Path $base -Force | Out-Null
  Copy-Item -LiteralPath $sourceExe -Destination $official
}

"== 4/4 校验基底 =="
$sha = Get-Sha256Hex $official
$size = (Get-Item -LiteralPath $official).Length
"文件  : $official"
"大小  : {0:N1} MB" -f ($size / 1MB)
"sha256: $sha"

$expected = if ($lock -and [string]$lock.client_version -eq $target) { [string]$lock.official_exe_sha256 } else { '' }
if ($expected -and $expected -ne $sha) {
  Write-Warning "基底哈希与 upstream-win.json 不符（期望 $expected）。注入锚点可能已漂移，构建大概率失败。"
  $match = $false
} elseif ($expected) {
  '哈希  : 与锁定值一致，锚点适配版本正确'
  $match = $true
} else {
  '哈希  : 无锁定值可比对（非适配版本）'
  $match = $null
}

$info = [ordered]@{
  version      = $target
  base         = $base
  official     = $official
  sha256       = $sha
  size         = $size
  expected     = $expected
  hash_matched = $match
  fetched_at   = (Get-Date).ToString('s')
}
$outFile = Join-Path $Root 'build\official\current.json'
New-Item -ItemType Directory -Path (Split-Path $outFile -Parent) -Force | Out-Null
# 不能带 BOM：Node 侧 JSON.parse 会把 \ufeff 当非法字符
[IO.File]::WriteAllText($outFile, ($info | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
"清单已写入: $outFile"
$info | ConvertTo-Json
