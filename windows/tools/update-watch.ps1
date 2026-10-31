<#
  官方更新跟进流水线（默认只准备基底，不动 app\）

  流程：
    1. 查官方清单，拿到最新版本与安装包地址
    2. 下载安装包到 build\updates\<版本>\
    3. NSIS 静默解包到 build\updates\<版本>\app\
    4. 把新版主程序复制成 build\updates\<版本>\base\WuwaTappo.official.exe
    5. 在该基底上试跑注入（解包 + build_integration），只生成 staging，不碰 app\
    6. 输出结论文本：锚点是否全命中

  用法：
    powershell -ExecutionPolicy Bypass -File tools\update-watch.ps1            # 只检查 + 下载 + 解包 + 试注入
    powershell -ExecutionPolicy Bypass -File tools\update-watch.ps1 -SkipBuild # 只检查版本

  注意：注入成功 ≠ 功能正常。staging 通过后仍需 tools\build.ps1 -Base <新基底> 全量重建并冒烟，
        再手工替换 app\（旧目录改名留作回滚）。
#>
param([switch]$SkipBuild, [string]$Installer, [switch]$Force)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Py = Join-Path $Root '.venv\Scripts\python.exe'
$AssetsHost = 'https://mc-wuwatappo.kurogames-global.com'

function Get-Json([string]$url) {
  # 兼容 Windows PowerShell 5.1 与 PowerShell 7，直连不走系统代理
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
  $wc = New-Object System.Net.WebClient
  $wc.Proxy = $null
  $wc.Encoding = [Text.Encoding]::UTF8
  $wc.Headers.Add('User-Agent', 'WuwaTappo-FullAtlas-UpdateCheck/1.0')
  try {
    return ($wc.DownloadString($url) | ConvertFrom-Json)
  } finally { $wc.Dispose() }
}

function Get-LocalBaseVersion {
  $cfg = Join-Path $Root 'build\local_config.json'
  if (Test-Path -LiteralPath $cfg) { return [string](Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).client_version }
  return ''
}

"== 1/5 查询官方版本 =="
$hostJson = Get-Json "$AssetsHost/app/json-host/latest_host.json"
$manifest = Get-Json ([string]$hostJson.url)
$remoteVer = [string]$manifest.version
$url = [string]$manifest.platforms.'windows-x86_64'.url
$localVer = Get-LocalBaseVersion
"官方: $remoteVer   本地基底: $localVer"
"安装包: $url"

if (-not $Force) {
  try {
    if ([version]($remoteVer -replace '[^0-9.].*$', '') -le [version]($localVer -replace '[^0-9.].*$', '')) {
      "官方版本不高于本地基底，无需处理（要强制继续加 -Force）。"
      return
    }
  } catch { "版本号无法比较，继续执行。" }
}
if ($SkipBuild) { return }

"== 2/5 下载安装包 =="
$workDir = Join-Path $Root "build\updates\$remoteVer"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
if ($Installer) {
  $setup = $Installer
  "使用指定安装包: $setup"
} else {
  $setup = Join-Path $workDir (Split-Path $url -Leaf)
  if ((Test-Path -LiteralPath $setup) -and -not $Force) {
    "已存在，跳过下载: $setup"
  } else {
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }
    $dl = New-Object System.Net.WebClient
    $dl.Proxy = $null
    $dl.Headers.Add('User-Agent', 'WuwaTappo-FullAtlas-UpdateCheck/1.0')
    try {
      $dl.DownloadFile($url, $setup)
    } finally { $dl.Dispose() }
    "下载完成: {0:N1} MB" -f ((Get-Item -LiteralPath $setup).Length / 1MB)
  }
}
if (-not (Test-Path -LiteralPath $setup)) { throw "安装包不存在: $setup" }

"== 3/5 静默解包（NSIS /S /D=）=="
$extractDir = Join-Path $workDir 'app'
if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
$proc = Start-Process -FilePath $setup -ArgumentList '/S', "/D=$extractDir" -Wait -PassThru
$inner = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'WuwaTappo.exe' -ErrorAction SilentlyContinue |
  Sort-Object Length -Descending | Select-Object -First 1
if (-not $inner) {
  throw "解包后未找到 WuwaTappo.exe（退出码 $($proc.ExitCode)）。请手工解包后把内层主程序放到 $workDir\base\WuwaTappo.official.exe 再重跑。"
}
"内层主程序: $($inner.FullName)  ({0:N1} MB)" -f ($inner.Length / 1MB)

"== 4/5 准备新基底 =="
$newBase = Join-Path $workDir 'base'
if (Test-Path -LiteralPath $newBase) { Remove-Item -LiteralPath $newBase -Recurse -Force }
New-Item -ItemType Directory -Path $newBase -Force | Out-Null
Copy-Item -LiteralPath $inner.FullName -Destination (Join-Path $newBase 'WuwaTappo.official.exe')
"基底: $newBase"

"== 5/5 试跑注入（只生成 staging，不动 app\）=="
$stagingRoot = Join-Path $workDir 'staging'
if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
$env:WUWA_EXTRACT_ROOT = $newBase
& $Py (Join-Path $Root 'src\tools\extract_static.py') (Join-Path $newBase 'WuwaTappo.official.exe')
if ($LASTEXITCODE -ne 0) { throw '解包失败（extract_static.py）' }

$env:WUWA_BUILD_ROOT = $stagingRoot
& $Py (Join-Path $Root 'src\tools\build_integration.py')
$code = $LASTEXITCODE

""
if ($code -ne 0) {
  "注入失败（退出码 $code）。大概率是锚点漂移，日志里会指出具体哪一处。"
  "app\ 未被改动，可继续用旧版。把上面的报错发我，通常几十行代码就能补上。"
  exit $code
}

"注入成功，staging 产物在: $stagingRoot"
@{
  version = $remoteVer
  built_at = (Get-Date).ToString('s')
  base = $newBase
  staging = $stagingRoot
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workDir 'stage_result.json') -Encoding UTF8

"下一步（确认要升级时）："
"  1) powershell -File tools\build.ps1 -Base `"$newBase`""
"  2) 冒烟：双击 app\WuwaTappoLauncher.exe，看设置里图鉴是否正常"
"  3) 回滚：把 app\ 改名为 app.old，旧目录随时可用"
