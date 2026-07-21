[CmdletBinding()]
param(
    [ValidateSet("WaitAndClean", "CleanNow")]
    [string]$Mode = "WaitAndClean"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Join-Path $env:ProgramData "HealthRestorer"
$logPath = Join-Path $root "health-restorer.log"
$stateTextPath = Join-Path $root "state.txt"
$stateJsonPath = Join-Path $root "state.json"
$taskName = "HealthRestorer-SecureDeletedData"
$powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param([string]$Message)

    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Add-Content -LiteralPath $logPath -Encoding UTF8 -Value (
        "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    )
}

function Test-MainWorkflowCompleted {
    if (Test-Path $stateJsonPath) {
        try {
            $state = Get-Content -LiteralPath $stateJsonPath -Raw | ConvertFrom-Json
            if ([string]$state.Stage -eq "Completed") {
                return $true
            }
        }
        catch {
            Write-Log ("Could not read state.json: {0}" -f $_.Exception.Message)
        }
    }

    if (Test-Path $stateTextPath) {
        try {
            if ((Get-Content -LiteralPath $stateTextPath -Raw).Trim() -eq "Completed") {
                return $true
            }
        }
        catch {
            Write-Log ("Could not read state.txt: {0}" -f $_.Exception.Message)
        }
    }

    return $false
}

function Get-VolumeMediaKind {
    param([Parameter(Mandatory)][string]$DriveLetter)

    try {
        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $disk = $partition | Get-Disk -ErrorAction Stop

        if ($disk.BusType -contains "NVMe") {
            return "SSD"
        }

        $physicalDisk = Get-PhysicalDisk -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DeviceId -eq [string]$disk.Number -or
                $_.FriendlyName -eq $disk.FriendlyName
            } |
            Select-Object -First 1

        if ($null -ne $physicalDisk) {
            $reportedType = [string]$physicalDisk.MediaType

            if ($reportedType -eq "SSD") {
                return "SSD"
            }

            if ($reportedType -eq "HDD") {
                return "HDD"
            }
        }

        $description = "{0} {1}" -f $disk.FriendlyName, $disk.Model

        if ($description -match "(?i)SSD|NVMe|Solid State") {
            return "SSD"
        }

        if ($description -match "(?i)HDD|Hard Disk") {
            return "HDD"
        }
    }
    catch {
        Write-Log ("Could not identify media type for {0}: {1}" -f $DriveLetter, $_.Exception.Message)
    }

    return "Unknown"
}

function Invoke-ReTrim {
    param([Parameter(Mandatory)][string]$DriveLetter)

    Write-Log ("Running TRIM/ReTrim on {0}:" -f $DriveLetter)

    Optimize-Volume `
        -DriveLetter $DriveLetter `
        -ReTrim `
        -Verbose `
        -ErrorAction Stop 4>&1 |
        ForEach-Object { Write-Log ([string]$_) }
}

function Invoke-FreeSpaceOverwrite {
    param([Parameter(Mandatory)][string]$DriveRoot)

    Write-Log ("Overwriting free space on {0} with cipher /w." -f $DriveRoot)

    $process = Start-Process `
        -FilePath "cipher.exe" `
        -ArgumentList @("/w:$DriveRoot") `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    Write-Log ("cipher /w exit code for {0}: {1}" -f $DriveRoot, $process.ExitCode)

    if ($process.ExitCode -ne 0) {
        throw "cipher /w failed for $DriveRoot with exit code $($process.ExitCode)."
    }
}

function Clear-DeletedData {
    $volumes = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Where-Object {
            $_.DeviceID -and
            $_.FileSystem -eq "NTFS"
        }

    foreach ($volume in $volumes) {
        $driveLetter = $volume.DeviceID.TrimEnd(":")
        $driveRoot = "{0}:\" -f $driveLetter
        $mediaKind = Get-VolumeMediaKind -DriveLetter $driveLetter

        Write-Log ("Deleted-data cleanup for {0}. Detected media: {1}." -f $driveRoot, $mediaKind)

        switch ($mediaKind) {
            "HDD" {
                Invoke-FreeSpaceOverwrite -DriveRoot $driveRoot
            }

            "SSD" {
                Invoke-ReTrim -DriveLetter $driveLetter
                Write-Log (
                    "SSD note: TRIM was issued, but software cannot guarantee physical overwrite of every NAND block."
                )
            }

            default {
                Write-Log (
                    "Unknown media type for {0}. ReTrim is used to avoid unnecessary writes to a possible SSD." -f $driveRoot
                )

                try {
                    Invoke-ReTrim -DriveLetter $driveLetter
                }
                catch {
                    Write-Log ("ReTrim was not supported for {0}: {1}" -f $driveRoot, $_.Exception.Message)
                }
            }
        }
    }
}

if (-not (Test-Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode"
    Start-Process -FilePath $powerShellPath -Verb RunAs -ArgumentList $arguments
    exit
}

try {
    if ($Mode -eq "WaitAndClean") {
        Write-Log "Secure deleted-data cleanup is waiting for the main workflow to complete."
        $deadline = (Get-Date).AddDays(7)

        while (-not (Test-MainWorkflowCompleted)) {
            if ((Get-Date) -ge $deadline) {
                throw "The main workflow did not reach Completed state within seven days."
            }

            Start-Sleep -Seconds 60
        }

        Start-Sleep -Seconds 30
    }

    Clear-DeletedData
    Write-Log "Deleted-data cleanup completed."

    $reportPath = Join-Path $env:PUBLIC "Desktop\HealthRestorer-report.txt"
    Add-Content -LiteralPath $reportPath -Encoding UTF8 -Value @(
        ""
        "Deleted-data cleanup completed: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "HDD: free space overwritten with cipher /w."
        "SSD: TRIM/ReTrim issued; physical overwrite of every NAND block cannot be guaranteed."
    ) -ErrorAction SilentlyContinue

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}
catch {
    Write-Log ("Deleted-data cleanup failed: {0}" -f $_.Exception.Message)
    throw
}
