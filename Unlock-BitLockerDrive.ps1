#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Secure-drive gatekeeper: prompts for the BitLocker password of a data drive
  and mounts it ONLY if the password is correct. Otherwise the volume stays
  locked AND has no drive letter (fully unmounted).

.DESCRIPTION
  - Designed to run via Task Scheduler at user logon and at every workstation
    unlock (i.e., every wake from sleep).
  - Safe-by-default: cancels and exits -> drive stays locked/unmounted.
  - The password is NEVER stored or logged. "Verification" = the actual
    BitLocker unlock API call; it only succeeds with the correct password.

.PARAMETER DriveLetter
  Letter of the BitLocker data drive (default D:).

.PARAMETER MaxAttempts
  Wrong-answer attempts before the prompt closes (default 3).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Unlock-BitLockerDrive.ps1 -DriveLetter D:
#>
[CmdletBinding()]
param(
    [string]$DriveLetter = 'D:',
    [int]$MaxAttempts   = 3,
    [string]$LogDir     = "$env:ProgramData\BitLockerUnlock"
)

$ErrorActionPreference = 'Stop'
$DriveLetter = $DriveLetter.TrimEnd(':').ToUpper()
$logFile  = Join-Path $LogDir  "unlock-$DriveLetter.log"
$guidFile = Join-Path $LogDir  "volume-$DriveLetter.guid"

function Write-Log([string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME, $Message
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

try {
    # ---------- 1. Resolve the volume (by letter, else by stored GUID) ----------
    $mountPoint = $null
    $blv = Get-BitLockerVolume -ErrorAction SilentlyContinue |
           Where-Object { $_.MountPoint -eq "$DriveLetter`:\" } | Select-Object -First 1
    if ($blv) {
        $mountPoint = "$DriveLetter`:\"
        $volPath = (Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue).Path
        if ($volPath) { Set-Content -Path $guidFile -Value $volPath.TrimEnd('\') }
    }
    elseif (Test-Path $guidFile) {
        $mountPoint = (Get-Content $guidFile -Raw).Trim()
        $blv = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop
    }
    else {
        Write-Log "ERROR: drive $DriveLetter not found and no stored volume GUID exists."
        exit 1
    }

    # ---------- 2. Sanity checks ----------
    if ($blv.VolumeStatus -eq 'FullyDecrypted') {
        Write-Log "ERROR: drive $DriveLetter is not BitLocker encrypted."
        exit 1
    }
    $hasPw = $blv.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'Password' }
    if (-not $hasPw) {
        Write-Log "ERROR: no Password key protector on $DriveLetter. Add one: Add-BitLockerKeyProtector -MountPoint $DriveLetter -PasswordProtector"
        exit 1
    }

    # ---------- 3. Enforce locked state (even if someone unlocked it) ----------
    if ($blv.LockStatus -eq 'Unlocked') {
        Lock-BitLocker -MountPoint $mountPoint
        Start-Sleep -Seconds 1
        Write-Log "Drive was unlocked; re-locked to enforce policy."
    }

    # ---------- 4. Remove the drive letter -> unmounted, invisible ----------
    if (Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue) {
        mountvol "$DriveLetter`:" /d
        Write-Log "Drive letter $DriveLetter removed; volume is unmounted."
    }

    # ---------- 5. GUI password prompt (retry loop) ----------
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $attempts = 0
    while ($true) {
        $form = New-Object System.Windows.Forms.Form
        $form.Text              = "Secure Storage - Drive $DriveLetter"
        $form.ClientSize        = New-Object System.Drawing.Size(390, 170)
        $form.StartPosition     = 'CenterScreen'
        $form.TopMost           = $true
        $form.FormBorderStyle   = 'FixedDialog'
        $form.MaximizeBox       = $false
        $form.MinimizeBox       = $false

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text     = "Drive $DriveLetter is locked and unmounted.`r`n`r`nEnter the BitLocker password to mount it.`r`n(Attempts remaining: $($MaxAttempts - $attempts))"
        $lbl.Location = New-Object System.Drawing.Point(15, 10)
        $lbl.Size     = New-Object System.Drawing.Size(355, 65)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Location            = New-Object System.Drawing.Point(15, 80)
        $txt.Size                = New-Object System.Drawing.Size(355, 24)
        $txt.UseSystemPasswordChar = $true

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text         = 'Unlock'
        $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $btnOk.Location     = New-Object System.Drawing.Point(210, 112)
        $btnOk.Size         = New-Object System.Drawing.Size(75, 28)

        $btnNo = New-Object System.Windows.Forms.Button
        $btnNo.Text         = 'Keep Locked'
        $btnNo.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $btnNo.Location     = New-Object System.Drawing.Point(295, 112)
        $btnNo.Size         = New-Object System.Drawing.Size(80, 28)

        $form.AcceptButton = $btnOk
        $form.CancelButton = $btnNo
        $form.Controls.AddRange(@($lbl, $txt, $btnOk, $btnNo))

        $res   = $form.ShowDialog()
        $typed = $txt.Text
        $form.Dispose()

        if ($res -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-Log "User chose 'Keep Locked'; drive stays unmounted."
            exit 0
        }

        $sec = ConvertTo-SecureString $typed -AsPlainText -Force
        try {
            Unlock-BitLocker -MountPoint $mountPoint -Password $sec -ErrorAction Stop
            Start-Sleep -Milliseconds 500
            $guidPath = (Get-Content $guidFile -Raw).Trim()
            mountvol "$DriveLetter`:" $guidPath
            Write-Log "SUCCESS: correct password; drive $DriveLetter mounted."
            [void][System.Windows.Forms.MessageBox]::Show(
                "Drive $DriveLetter mounted successfully.",
                'Access Granted', 'OK', 'Information')
            exit 0
        }
        catch {
            $attempts++
            Write-Log "FAILED: wrong password (attempt $attempts of $MaxAttempts)."
            if ($attempts -ge $MaxAttempts) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Too many failed attempts.`r`nDrive $DriveLetter remains locked and unmounted.",
                    'Access Denied', 'OK', 'Warning')
                Write-Log "Max attempts reached; drive stays locked."
                exit 1
            }
        }
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)"
    exit 1
}
