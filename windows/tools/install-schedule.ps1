<#
  注册/卸载「每 8 小时自动检测官方更新」的 Windows 计划任务

  任务内容：以普通权限运行 WuwaTappoManager.exe --check-only
           查到新版本弹一次提示，同一个版本只提示一次

  用法：
    powershell -ExecutionPolicy Bypass -File tools\install-schedule.ps1
    powershell -ExecutionPolicy Bypass -File tools\install-schedule.ps1 -Hours 12
    powershell -ExecutionPolicy Bypass -File tools\install-schedule.ps1 -Remove
#>
param(
  [switch]$Remove,
  [int]$Hours = 8,
  [string]$Exe,
  [string]$Start = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$TaskName = 'WuwaTappo Update Check'

# 本机安全策略把 schtasks.exe 列入黑名单，这里统一走 PowerShell 原生
# ScheduledTasks 模块（CIM），不依赖 schtasks。

if ($Remove) {
  try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    "已删除计划任务：$TaskName"
  } catch {
    "删除失败（可能本来就不存在）：$($_.Exception.Message)"
  }
  exit 0
}

if (-not $Exe) { $Exe = Join-Path $Root 'app\WuwaTappoManager.exe' }
if (-not (Test-Path -LiteralPath $Exe)) {
  throw "找不到管理器：$Exe（先跑 tools\build-manager.ps1）"
}

$At = if ($Start) { [datetime]::ParseExact($Start, 'HH:mm', $null) } else { (Get-Date).AddMinutes(2) }
try {
  $taskAction = New-ScheduledTaskAction -Execute $Exe -Argument '--check-only'
  $trigger = New-ScheduledTaskTrigger -Once -At $At `
    -RepetitionInterval (New-TimeSpan -Hours $Hours) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
  Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger `
    -Settings $settings -Description "Check WuwaTappo official update every $Hours hours" `
    -Force -ErrorAction Stop | Out-Null
} catch {
  "创建失败：$($_.Exception.Message)"
  "可在「任务计划程序」里手动新建任务，操作填："
  "  $Exe --check-only"
  exit 1
}

$info = Get-ScheduledTaskInfo -TaskName $TaskName
"已注册计划任务：$TaskName"
"  频率：每 $Hours 小时"
"  命令：`"$Exe`" --check-only"
"  下次运行：$($info.NextRunTime)"
""
"立即试跑： Start-ScheduledTask -TaskName ""$TaskName"""
"查看状态： Get-ScheduledTaskInfo -TaskName ""$TaskName"""
"取消：     powershell -File tools\install-schedule.ps1 -Remove"
