# Windows Microsoft Secure Boot CA 2023 Update

## Overview
> [!IMPORTANT]
> Microsoft is planning to release these updates through normal Windows Update channels. It is highly recommended to use those official channels instead of this script. This script is intended as a backup plan or manual remediation tool if the standard updates are not applicable or fail to apply.

This repository contains a PowerShell script designed to automate the validation and installation of the **Microsoft Windows UEFI CA 2023** certificate into the system's Secure Boot Database (DB). This update is crucial for ensuring the system trusts newer bootloaders signed by Microsoft.

## Script: `Invoke-SecureBoot2023CA.ps1`

### Description
The script interacts with the UEFI firmware variables to detect if the new CA certificate is present. If it is missing, it utilizes the standard Microsoft method (Registry Key + Scheduled Task) to stage the update for the next reboot. It includes logic to register itself as a scheduled task to run on startup until validation succeeds.

### Recommended Usage
The most reliable way to apply this update is using the `-CreateScheduledTask` parameter. This automates the process across the multiple reboots required for UEFI variable updates. 

1. Run the script: `.\Invoke-SecureBoot2023CA.ps1 -CreateScheduledTask`
2. Reboot the system 2-3 times.

All activity is logged to `C:\Windows\Logs\UEFICA2023\`. The scheduled task is **self-cleaning**: it will be automatically deleted once the certificate is successfully verified or if the script file itself is removed from the system.

### Key Features

**Automated Persistence**
Recommended for production environments. Sets up the persistent task to handle reboots and validation automatically.
```powershell
.\Invoke-SecureBoot2023CA.ps1 -CreateScheduledTask
```
*   **UEFI Variable Inspection**: Directly reads the `db` variable using `Get-SecureBootUEFI` to verify certificate presence.
*   **Idempotency**: detailed state tracking ensures the script handles multiple reboots intelligently and does not run unnecessarily if a "Success" stamp exists.
*   **Safety First**: Defaults to a "Dry Run" mode unless the `-Production` switch is explicitly provided.
*   **Validation Tracker**: Requires the certificate to be detected across specific boot sessions before marking the remediation as fully complete.
*   **Self-Cleanup**: Automatically removes the scheduled task once the update is verified and the success stamp is created.

### Parameters

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `-Production` | Switch | Enables active changes. Without this, the script only logs what it *would* do (Dry Run). |
| `-Reboot` | Switch | If the certificate is missing and the fix is applied, the script will automatically restart the computer. |
| `-CreateScheduledTask` | Switch | Creates a persistent scheduled task to run this script on system startup. |

### Usage Examples

**1. Check Status (Dry Run)**
Logs whether the certificate is found or missing without making changes.
```powershell
.\Invoke-SecureBoot2023CA.ps1
```

**2. Apply Update and Reboot**
Checks for the certificate. If missing, applies the registry fix and reboots immediately.
```powershell
.\Invoke-SecureBoot2023CA.ps1 -Production -Reboot
```

### Technical Workflow
1.  **Permission Check**: Verifies the script is running as Administrator.
2.  **Stamp Check**: Looks for `%SystemRoot%\Logs\UEFICA2023\Success.tag`. If found, exits.
3.  **UEFI Check**: Scans the UEFI `db` for the string "Windows UEFI CA 2023".
4.  **Remediation (If Missing)**:
    *   Sets Registry: `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\AvailableUpdates` = `0x40`.
    *   Starts Task: `\Microsoft\Windows\PI\Secure-Boot-Update`.
    *   Reboots if requested.
5.  **Validation (If Found)**:
    *   If running in production, it tracks the number of boot sessions where the cert was seen.
    *   Once confirmed stable (Count >= 2), creates the `Success.tag`.

### Logging
Logs are generated in `C:\Windows\Logs\UEFICA2023\` (assuming standard SystemRoot):
*   **Cert_Exists.log**: Logging for successful detection.
*   **Cert_Update.log**: Logging for remediation actions and errors.
*   **ValidationTracker.xml**: Stores state between reboots.
*   **Success.tag**: An empty file indicating the workflow is complete.
