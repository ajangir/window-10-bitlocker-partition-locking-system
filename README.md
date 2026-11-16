# window-10-bitlocker-partition-locking-system
 window-10-bitlocker-partition-lock using bitlocker encryption and locking unlocking system

How it works
plain

Wake/logon → Task Scheduler fires → script strips drive letter →
GUI password prompt → Unlock-BitLocker call (the real password check) →
match: letter restored, disk mounted | no match/cancel: stays unmounted
Workstation lock → second task re-locks + removes letter again

Key design point: there is no stored copy of the password to "check against" — the script passes what you type straight into the Unlock-BitLocker API, which only succeeds with the correct password. Nothing is written to disk or logs.
Step 1 — One-time prep (data drive)
Run elevated, once:
powershell

# Give the data drive a password protector (if not already done)
Add-BitLockerKeyProtector -MountPoint 'D:' -PasswordProtector

# Make sure auto-unlock is OFF (otherwise Windows mounts it silently)
Clear-BitLockerAutoUnlock

Step 2 — Deploy the scripts

    Copy the three files to C:\ProgramData\BitLockerUnlock\
    Run Register-BitLockerUnlockTasks.ps1 as the user who must see the prompts (elevated). It creates:
        BL-UnlockOnLogonAndWake — triggers: user logon + workstation unlock (that is your "each wake from sleep"), runs with highest privileges while the user is logged on, so the GUI appears on their desktop.
        BL-LockOnWorkstationLock — trigger: workstation lock, re-locks and unmounts the drive every time the user locks the machine or it sleeps.

Note: "highest privileges" means the account must be a local admin — a standard user's task can't unlock BitLocker. The GUI runs in the interactive session, not as SYSTEM (a SYSTEM task can't show a window on the user's desktop — that's why this approach is used).
Step 3 — Test
powershell

# Run the unlock script manually first to validate
C:\ProgramData\BitLockerUnlock\Unlock-BitLockerDrive.ps1 -DriveLetter D

# Verify state before/after
Get-BitLockerVolume D:        # LockStatus: Locked / Unlocked

Logs go to C:\ProgramData\BitLockerUnlock\unlock-D.log.
The unlock script (core logic)
The flow: resolve volume → verify it's encrypted and has a password protector → force-lock it even if already unlocked → remove the drive letter → show the WinForms password box → up to 3 attempts → on success, Unlock-BitLocker + restore the letter; on cancel/3 failures, exit silently with the drive unmounted. Failure is always the safe end state.
Honest security caveats (important for a defence context)

    This is a gatekeeper, not a boundary. Any local admin can bypass it in seconds with manage-bde -unlock D: -pw. The real protection is BitLocker itself + the drive having no letter + NTFS ACLs. On a defence desktop, also restrict who knows the password and audit unlock-D.log.
    While the PC is on and the drive is mounted, the files are readable by any process running as that user — that's why I included the lock-on-workstation-lock task, so the drive seals itself every time the user steps away.
    Sleep (S3) leaves the RAM image alive; for a true at-rest guarantee against DMA/cold-boot, the earlier hibernate/TPM+PIN approach remains the stronger control. This script protects the data drive at the OS level.

