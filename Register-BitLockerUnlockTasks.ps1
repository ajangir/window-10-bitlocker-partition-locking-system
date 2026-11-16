#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Registers the Task Scheduler jobs that:
    1. Show the BitLocker password GUI  -> at every user LOGON
    2. Show the BitLocker password GUI  -> at every WORKSTATION UNLOCK (= wake from sleep)
    3. Re-lock + unmount the drive      -> at every WORKSTATION LOCK

  Run once as the user who must see the prompts. The task runs with the
  HIGHEST privileges of that (admin) account, only while logged on, so the
  GUI appears on the user's desktop.
#>
[CmdletBinding()]
param(
    [string]$InstallDir  = 'C:\ProgramData\BitLockerUnlock',
    [string]$DriveLetter = 'D:',
    [string]$UnlockTask  = 'BL-UnlockOnLogonAndWake',
    [string]$LockTask    = 'BL-LockOnWorkstationLock'
)

$ErrorActionPreference = 'Stop'
$unlockScript = Join-Path $InstallDir 'Unlock-BitLockerDrive.ps1'
$lockScript   = Join-Path $InstallDir 'Lock-BitLockerDrive.ps1'

if (-not (Test-Path $unlockScript)) { throw "Missing $unlockScript - copy scripts to $InstallDir first." }

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Host "Registering tasks for: $currentUser"

# ---- Trigger helper: session state change (lock / unlock) ----
function New-StateChangeTrigger([int]$State, [string]$User) {
    New-CimInstance -ClassName MSFT_TaskSessionStateChangeTrigger `
        -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly `
        -Property @{ StateChange = $State; UserId = $User }
}
# StateChange values: 7 = SessionLock, 8 = SessionUnlock

$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -StartWhenAvailable

# ================= Task 1: unlock GUI on logon + wake =================
$logonTrigger  = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$unlockTrigger = $null
try { $unlockTrigger = New-StateChangeTrigger -State 8 -User $currentUser }
catch { Write-Warning "Auto-add of 'on workstation unlock' failed. Add it manually: taskschd.msc -> $UnlockTask -> Triggers -> New -> 'On workstation unlock'." }

$actionUnlock = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$unlockScript`" -DriveLetter $DriveLetter"

$triggers = @($logonTrigger)
if ($unlockTrigger) { $triggers += $unlockTrigger }

Register-ScheduledTask -TaskName $UnlockTask -Action $actionUnlock -Trigger $triggers `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Task '$UnlockTask' registered (triggers: user logon$(if($unlockTrigger){' + workstation unlock'}))."

# ================= Task 2: lock + unmount on workstation lock =================
if (Test-Path $lockScript) {
    $lockTrigger = $null
    try { $lockTrigger = New-StateChangeTrigger -State 7 -User $currentUser }
    catch { Write-Warning "Auto-add of 'on workstation lock' failed. Add it manually for task $LockTask." }

    if ($lockTrigger) {
        $actionLock = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$lockScript`" -DriveLetter $DriveLetter"
        Register-ScheduledTask -TaskName $LockTask -Action $actionLock -Trigger $lockTrigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "Task '$LockTask' registered (trigger: workstation lock)."
    }
}
else {
    Write-Warning "Lock script not found at $lockScript - skipping lock-on-workstation-lock task."
}

Write-Host ""
Write-Host "Done. Test: run '$unlockScript' manually once, then check:"
Write-Host "  Get-BitLockerVolume $DriveLetter"
