#Requires -Version 5.1
<#
.SYNOPSIS
    注册/更新「大肥鱼 每日巡检」计划任务（每天 07:30 跑 tests\Nightly-Check.ps1）。

.DESCRIPTION
    只做一件事：把巡检脚本挂到计划任务上。重复运行是安全的（先删后建）。
    参数与 Nightly-Check.ps1 保持一致，默认值就用仓库里的约定。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Register-Nightly.ps1
    注册后立刻试跑一次：  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Register-Nightly.ps1 -RunNow
#>
[CmdletBinding()]
param(
    [string]$TaskName = '大肥鱼 每日巡检',
    [string]$Repo = 'E:\DSHWORK\repo\大肥鱼操作系统',
    [string]$At = '07:30',
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $Repo 'tests\Nightly-Check.ps1'
if (-not (Test-Path $script)) { throw "找不到巡检脚本：$script" }

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $psExe `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script) `
    -WorkingDirectory $Repo

$trigger = New-ScheduledTaskTrigger -Daily -At $At

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

# 只在用户登录时跑：推送要用登录态里的 git 凭据
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "已删除旧任务：$TaskName"
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description '每天 07:30 检查桌面系统昨晚的测试/重构；无严重缺陷则推送到 dev 并生成汇报（不碰 main）。' | Out-Null

Write-Output "已注册：$TaskName（每天 $At）"
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State |
    Format-Table -AutoSize | Out-String | Write-Output

if ($RunNow) {
    Write-Output '--- 立刻试跑一次 ---'
    Start-ScheduledTask -TaskName $TaskName
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        if ($info.LastRunTime -gt (Get-Date).AddMinutes(-3) -and $info.LastTaskResult -ne 267009) { break }
    }
    Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object LastRunTime, LastTaskResult, NextRunTime |
        Format-List | Out-String | Write-Output
}
