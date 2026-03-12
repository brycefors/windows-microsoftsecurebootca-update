<#
.SYNOPSIS
    Validates and adds the Windows UEFI CA 2023 certificate to the Secure Boot DB.

.DESCRIPTION
    DISCLAIMER: Microsoft is planning to release these updates through normal Windows Update channels. 
    It is best to use those official channels instead of this script. This script serves as a backup 
    plan if the standard updates do not work or are unavailable.
    
    WARNING: Modifying UEFI Secure Boot variables carries inherent risks. Depending on your system's 
    firmware, applying this update could potentially cause the computer to fail to boot.

    This script checks if the "Windows UEFI CA 2023" is present in the UEFI 'db' variable.
    If missing, it attempts to enable the update via registry keys (Standard Microsoft Method).
    It supports a production flag for making changes and a reboot flag for restarting.
    It uses a stamp file to prevent re-running if previously successful.

.PARAMETER Production
    If specified, the script will apply changes (Registry updates and Stamp creation). 
    Without this, it runs in "Dry Run" mode.

.PARAMETER Reboot
    If specified, and changes were made, the system will automatically reboot.

.PARAMETER CreateScheduledTask
    If specified, creates a scheduled task to run this script with -Production on every system startup.
    The script will exit after creating the task. The task will automatically be deleted upon successful completion.

.EXAMPLE
    .\Invoke-SecureBoot2023CA.ps1
    Runs a dry run check. Logs if the certificate exists or is missing.

.EXAMPLE
    .\Invoke-SecureBoot2023CA.ps1 -Production -Reboot
    Checks for the certificate. If missing, applies the update registry key, and reboots.

.EXAMPLE
    .\Invoke-SecureBoot2023CA.ps1 -CreateScheduledTask
    Creates a scheduled task that will run this script on every reboot to apply and validate the fix.
#>

param (
    [Switch]$Production,
    [Switch]$Reboot,
    [Switch]$CreateScheduledTask
)

# ---------------------------------------------------------------------------
# Configuration Variables
# ---------------------------------------------------------------------------
$LogDir          = "$env:SystemRoot\Logs\UEFICA2023"
$LogFileExists   = Join-Path -Path $LogDir -ChildPath "Cert_Exists.log"
$LogFileUpdate   = Join-Path -Path $LogDir -ChildPath "Cert_Update.log"
$StampFile       = Join-Path -Path $LogDir -ChildPath "Success.tag"
$ValidationTracker = Join-Path -Path $LogDir -ChildPath "ValidationTracker.xml"
$TargetCertSubject = "Windows UEFI CA 2023"

# Microsoft Registry Key for enabling the 2023 Update
# Setting AvailableUpdates to 0x40 allows the OS to attempt the DB update
$RegPath         = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot"
$RegName         = "AvailableUpdates"
$RegValue        = 0x40

# Scheduled Task Configuration
$TaskName        = "UEFICA2023Update"
$TaskDescription = "Runs the UEFI CA 2023 update script on startup to validate and apply the certificate."

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------

function Write-Log {
    param (
        [string]$Message,
        [string]$Path
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] $Message"
    Write-Host $LogEntry
    if ($Production) {
        Add-Content -Path $Path -Value $LogEntry -Force
    } else {
        Write-Host "   [DryRun] Would write to: $Path" -ForegroundColor Gray
    }
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Main Execution
# ---------------------------------------------------------------------------

# 1. Prerequisite Checks
if (-not (Test-IsAdmin)) {
    Write-Warning "This script must be run as Administrator to access UEFI variables and manage Scheduled Tasks."
    exit
}

# Handle implied Production mode for task creation
if ($CreateScheduledTask -and -not $Production) { $Production = $true }

# 2. Ensure Log Directory Exists
if ($Production -and -not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# 3. Immediate Exit if success stamp already exists
if (Test-Path $StampFile) {
    Write-Log -Message "Success stamp found ($StampFile). Script has already run successfully. Exiting." -Path $LogFileExists
    exit
}

# 4. UEFI Assessment
try {
    # Get the 'db' variable. This requires a UEFI system and Admin rights.
    $SecureBootDB = Get-SecureBootUEFI -Name db -ErrorAction Stop
    $BytesString  = [System.Text.Encoding]::ASCII.GetString($SecureBootDB.Bytes)
    $CertFound    = $BytesString -match $TargetCertSubject
}
catch {
    Write-Log -Message "Failed to read UEFI 'db' variable: $($_.Exception.Message)" -Path $LogFileUpdate
    if (-not $CreateScheduledTask) { exit 1 }
    $CertFound = $false # Fall through for task creation if we can't check yet
}

# 5. Unified Success Handling
if ($CertFound) {
    if ($CreateScheduledTask) {
        Write-Host "Certificate '$TargetCertSubject' is already present. Scheduled task will not be created."
    }

    if ($Production) {
        Write-Log -Message "Success: Certificate '$TargetCertSubject' found. Finalizing." -Path $LogFileExists
        New-Item -Path $StampFile -ItemType File -Force | Out-Null
        
        # Clean up scheduled task if it exists
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Log -Message "Removed existing scheduled task '$TaskName'." -Path $LogFileUpdate
        }
        Write-Host "Success: Certificate is present. Success stamp created."
    } else {
        Write-Log -Message "Validation Passed (Dry Run): '$TargetCertSubject' is present." -Path $LogFileExists
    }
    exit
}

# Handle Scheduled Task Creation
if ($CreateScheduledTask) {
    Write-Log -Message "Creating scheduled task '$TaskName' to run this script on startup." -Path $LogFileUpdate

    try {
        # Get the full path to the current script
        $ScriptPath = $PSCommandPath
        if (-not $ScriptPath) {
            throw "Could not determine the script's own path. Please run from a saved .ps1 file."
        }

        # Logic to run the script, or delete the task if the script file is missing
        $TaskCmd = "if (Test-Path '$ScriptPath') { & '$ScriptPath' -Production } else { Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false -ErrorAction SilentlyContinue }"
        $Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -Command `"$TaskCmd`""
        $Trigger = New-ScheduledTaskTrigger -AtStartup
        $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        # Check if task already exists
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Write-Log -Message "Task '$TaskName' already exists. Updating it." -Path $LogFileUpdate
            Set-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings
        } else {
            Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description $TaskDescription -Force
        }

        Write-Log -Message "Scheduled task '$TaskName' created/updated successfully." -Path $LogFileUpdate

        Write-Log -Message "Starting scheduled task '$TaskName' immediately." -Path $LogFileUpdate
        Start-ScheduledTask -TaskName $TaskName

        # Verification that the task exists and is active
        Start-Sleep -Seconds 1
        $VerifyTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $VerifyTask) {
            throw "Scheduled task '$TaskName' was not found immediately after attempt to start it. This may occur if the script completed and self-deleted because the CA is already up to date."
        }
        Write-Log -Message "Task '$TaskName' verified. Current state: $($VerifyTask.State)" -Path $LogFileUpdate

        Write-Host "Task started and will also run on subsequent reboots until completion."
    }
    catch {
        Write-Log -Message "Error creating scheduled task: $($_.Exception.Message)" -Path $LogFileUpdate
        exit 1
    }
    
    exit 
}

# ---------------------------------------------------------------------------
# 2. Execution & State Tracking
# ---------------------------------------------------------------------------

# Track validations across reboots globally (cert might not appear immediately)
if ($Production) {
    $CurrentBootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $Tracker = [PSCustomObject]@{ Count = 0; LastBoot = $null }

    if (Test-Path $ValidationTracker) {
        try { $Tracker = Import-Clixml -Path $ValidationTracker -ErrorAction Stop }
        catch { Write-Log -Message "Tracker file invalid, resetting." -Path $LogFileExists }
    }

    # Only increment if this is a new boot session
    if ($Tracker.LastBoot -ne $CurrentBootTime) {
        $Tracker.LastBoot = $CurrentBootTime
        $Tracker.Count++
        $Tracker | Export-Clixml -Path $ValidationTracker -Force
        Write-Log -Message "New boot session detected. Validation count incremented to $($Tracker.Count)." -Path $LogFileExists
    }
}

# -----------------------------------------------------------------------
# Scenario: Certificate Missing - Remediation
# -----------------------------------------------------------------------
Write-Log -Message "Validation Failed: '$TargetCertSubject' is NOT found in the UEFI db." -Path $LogFileUpdate

if (-not $Production) {
    if (-not $CertFound) {
        Write-Host "WARNING: -Production flag not set. No changes will be made." -ForegroundColor Yellow
        Write-Host "ACTION: Would set registry key '$RegPath\$RegName' to '$RegValue'."
        if ($Reboot) { Write-Host "ACTION: Would reboot system." }
        exit
    }

}

# If this is not the first run (tracker count > 1), don't re-apply the fix. Just wait for reboots.
if ($Tracker.Count -gt 1) {
    Write-Log -Message "Remediation was previously applied. Waiting for reboot for changes to take effect. (Attempt: $($Tracker.Count))" -Path $LogFileUpdate
    exit
}

# Apply Fix
try {
    Write-Log -Message "Attempting to enable UEFI CA 2023 update via Registry..." -Path $LogFileUpdate

    # Check if path exists, create if not (unlikely for this specific key, but good practice)
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }

    # Set the Registry Key to trigger OS update handling
    Set-ItemProperty -Path $RegPath -Name $RegName -Value $RegValue -Type DWord -Force
    
    Write-Log -Message "Registry key set successfully." -Path $LogFileUpdate

    # Trigger the Secure Boot Update task to stage the change before reboot
    Write-Log -Message "Starting scheduled task: \Microsoft\Windows\PI\Secure-Boot-Update" -Path $LogFileUpdate
    Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update" | Out-Null

    # Wait for the task to finish
    while ((Get-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update").State -eq 'Running') {
        Start-Sleep -Seconds 1
    }

    # Handle Reboot
    if ($Reboot) {
        Write-Log -Message "Reboot flag detected. Restarting system in 5 seconds..." -Path $LogFileUpdate
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    }
    else {
        Write-Log -Message "Update applied. A manual reboot is required for the UEFI DB update to take effect." -Path $LogFileUpdate
    }

}
catch {
    Write-Log -Message "Error applying update: $($_.Exception.Message)" -Path $LogFileUpdate
    exit 1
}
