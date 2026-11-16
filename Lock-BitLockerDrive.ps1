#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Companion to Unlock-BitLockerDrive.ps1: re-locks the data drive and removes
  its drive letter whenever the workstation is locked (every walk-away).
  Run via Task Scheduler trigger 'On workstation lock' (SessionLock).
#>
[CmdletBinding()]
param(
    [string]$DriveLetter = 'D:',
    [string]$LogDir      = "$env:ProgramData\BitLockerUnlock"
)

$ErrorActionPreference = 'Stop'
$DriveLetter = $DriveLetter.TrimEnd(':').ToUpper()
$logFile = Join-Path $LogDir "unlock-$DriveLetter.log"

function Write-Log([string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME, $Message
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

try {
    $blv = Get-BitLockerVolume -ErrorAction SilentlyContinue |
           Where-Object { $_.MountPoint -eq "$DriveLetter`:\" } | Select-Object -First 1
    if (-not $blv) { exit 0 }            # already unmounted/letterless - fine
    if ($blv.LockStatus -eq 'Unlocked') {
        Lock-BitLocker -MountPoint "$DriveLetter`:\" 
        Write-Log "Workstation locked: drive $DriveLetter re-locked."
    }
    if (Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue) {
        mountvol "$DriveLetter`:" /d
    }
    exit 0
}
catch {
    Write-Log "FATAL (lock): $($_.Exception.Message)"
    exit 1
}
