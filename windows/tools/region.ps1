# 区域配置：国服 / 国际服。被 fetch-official / build / deploy / package 共同引用。
#
# 两侧的差别只在数据源与命名，构建链本身完全一致：
#   目录    build|app           vs build-global|app-global
#   锁定    upstream-win.json   vs upstream-win-global.json
#   素材源  mc-wuwatappo…       vs wutheringwaves-wuwatappo…
#   产物    WuwaTappo-Full-Community-Windows-x64-<ver>.zip
#           WuwaTappo-Global-Community-Windows-x64-<ver>.zip
function Get-RegionProfile {
  param([string]$Root, [string]$Region)

  if (-not $Region) { $Region = if ($env:WUWA_REGION) { $env:WUWA_REGION } else { 'cn' } }
  $Region = $Region.ToLowerInvariant()
  if ($Region -notin @('cn', 'global')) { throw "未知区域：$Region（可选 cn / global）" }
  $isGlobal = $Region -eq 'global'

  [pscustomobject]@{
    Id              = $Region
    Label           = $(if ($isGlobal) { '国际服' } else { '国服' })
    IsGlobal        = $isGlobal
    WorkDir         = Join-Path $Root $(if ($isGlobal) { 'build-global' } else { 'build' })
    AppDir          = Join-Path $Root $(if ($isGlobal) { 'app-global' } else { 'app' })
    LockFile        = Join-Path $Root $(if ($isGlobal) { 'upstream-win-global.json' } else { 'upstream-win.json' })
    AssetsHost      = $(if ($isGlobal) { 'https://wutheringwaves-wuwatappo.kurogames-global.com' } else { 'https://mc-wuwatappo.kurogames-global.com' })
    ApiBase         = $(if ($isGlobal) { 'https://api-wutheringwaves-wuwatappo.kurogames-global.com' } else { 'https://api-mc-wuwatappo.kurogames-global.com' })
    UpdaterHostFile = $(if ($isGlobal) { 'latest-global_host.json' } else { 'latest_host.json' })
    ArtifactPrefix  = $(if ($isGlobal) { 'WuwaTappo-Global-Community' } else { 'WuwaTappo-Full-Community' })
  }
}
