[CmdletBinding()]
param(
    [ValidateSet("WaitAndClean", "CleanNow")]
    [string]$Mode = "WaitAndClean"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Join-Path $env:ProgramData "HealthRestorer"
$LogPath = Join-Path $Root "health-restorer.log"
$StateTextPath = Join-Path $Root "state.txt"
$StateJsonPath = Join-Path $Root "state.json"
$TaskName = "HealthRestorer-SecureDeletedData"
$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$ResidueScript = Join-Path $Root "ProgramResidueCleanup.ps1"
$ResidueSummaryPath = Join-Path $Root "program-residue-summary.json"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param([string]$Text)
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text)
}

function Test-MainWorkflowCompleted {
    if (Test-Path $StateJsonPath) {
        try {
            $state = Get-Content -LiteralPath $StateJsonPath -Raw | ConvertFrom-Json
            if ([string]$state.Stage -eq "Completed") { return $true }
        } catch { Write-Log ("Could not read state.json: {0}" -f $_.Exception.Message) }
    }
    if (Test-Path $StateTextPath) {
        try {
            if ((Get-Content -LiteralPath $StateTextPath -Raw).Trim() -eq "Completed") { return $true }
        } catch { Write-Log ("Could not read state.txt: {0}" -f $_.Exception.Message) }
    }
    return $false
}

function Invoke-ProgramResidueCleanup {
    if (-not (Test-Path -LiteralPath $ResidueScript)) {
        throw "Program residue cleanup script was not found: $ResidueScript"
    }
    Remove-Item -LiteralPath $ResidueSummaryPath -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $PowerShell -ArgumentList @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", $ResidueScript,
        "-SummaryPath", $ResidueSummaryPath
    ) -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $ResidueSummaryPath)) {
        throw "Program residue cleanup failed with exit code $($process.ExitCode)."
    }
    return Get-Content -LiteralPath $ResidueSummaryPath -Raw | ConvertFrom-Json
}

function Get-VolumeMediaKind {
    param([Parameter(Mandatory)][string]$DriveLetter)
    try {
        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $disk = $partition | Get-Disk -ErrorAction Stop
        if ($disk.BusType -contains "NVMe") { return "SSD" }
        $physical = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq [string]$disk.Number -or $_.FriendlyName -eq $disk.FriendlyName } | Select-Object -First 1
        if ($null -ne $physical) {
            if ([string]$physical.MediaType -eq "SSD") { return "SSD" }
            if ([string]$physical.MediaType -eq "HDD") { return "HDD" }
        }
        $description = "{0} {1}" -f $disk.FriendlyName, $disk.Model
        if ($description -match "(?i)SSD|NVMe|Solid State") { return "SSD" }
        if ($description -match "(?i)HDD|Hard Disk") { return "HDD" }
    } catch { Write-Log ("Could not identify media type for {0}: {1}" -f $DriveLetter, $_.Exception.Message) }
    return "Unknown"
}

function Invoke-ReTrim {
    param([Parameter(Mandatory)][string]$DriveLetter)
    Write-Log ("Running TRIM/ReTrim on {0}:" -f $DriveLetter)
    Optimize-Volume -DriveLetter $DriveLetter -ReTrim -Verbose -ErrorAction Stop 4>&1 | ForEach-Object { Write-Log ([string]$_) }
}

function Invoke-FreeSpaceOverwrite {
    param([Parameter(Mandatory)][string]$DriveRoot)
    Write-Log ("Overwriting free space on {0} with cipher /w." -f $DriveRoot)
    $process = Start-Process "cipher.exe" -ArgumentList @("/w:$DriveRoot") -Wait -PassThru -WindowStyle Hidden
    Write-Log ("cipher /w exit code for {0}: {1}" -f $DriveRoot, $process.ExitCode)
    if ($process.ExitCode -ne 0) { throw "cipher /w failed for $DriveRoot with exit code $($process.ExitCode)." }
}

function Clear-DeletedData {
    $volumes = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Where-Object { $_.DeviceID -and $_.FileSystem -eq "NTFS" }
    foreach ($volume in $volumes) {
        $letter = $volume.DeviceID.TrimEnd(":")
        $driveRoot = "{0}:\" -f $letter
        $kind = Get-VolumeMediaKind $letter
        Write-Log ("Deleted-data cleanup for {0}. Detected media: {1}." -f $driveRoot, $kind)
        switch ($kind) {
            "HDD" { Invoke-FreeSpaceOverwrite $driveRoot }
            "SSD" {
                Invoke-ReTrim $letter
                Write-Log "SSD note: TRIM was issued, but software cannot guarantee physical overwrite of every NAND block."
            }
            default {
                Write-Log ("Unknown media type for {0}. ReTrim is used to avoid unnecessary writes to a possible SSD." -f $driveRoot)
                try { Invoke-ReTrim $letter } catch { Write-Log ("ReTrim was not supported for {0}: {1}" -f $driveRoot, $_.Exception.Message) }
            }
        }
    }
}

if (-not (Test-Administrator)) {
    Start-Process -FilePath $PowerShell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode"
    exit
}

try {
    if ($Mode -eq "WaitAndClean") {
        Write-Log "Secure cleanup is waiting for the main workflow to complete."
        $deadline = (Get-Date).AddDays(7)
        while (-not (Test-MainWorkflowCompleted)) {
            if ((Get-Date) -ge $deadline) { throw "The main workflow did not reach Completed state within seven days." }
            Start-Sleep -Seconds 60
        }
        Start-Sleep -Seconds 30
    }

    $residue = Invoke-ProgramResidueCleanup
    Clear-DeletedData
    Write-Log "Program residue and deleted-data cleanup completed."

    $report = Join-Path $env:PUBLIC "Desktop\HealthRestorer-report.txt"
    Add-Content -LiteralPath $report -Encoding UTF8 -Value @(
        ""
        "Program residue cleanup completed: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "Stale uninstall entries removed: $($residue.StaleUninstallEntries)"
        "Orphaned program folders removed: $($residue.OrphanedProgramFolders)"
        "Orphaned scheduled tasks removed: $($residue.OrphanedScheduledTasks)"
        "Orphaned services removed: $($residue.OrphanedServices)"
        "Broken shortcuts removed: $($residue.BrokenShortcuts)"
        "Empty program directories removed: $($residue.EmptyDirectories)"
        "Residue metadata backup: $($residue.BackupPath)"
        ""
        "Deleted-data cleanup completed: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "HDD: free space overwritten with cipher /w."
        "SSD: TRIM/ReTrim issued; physical overwrite of every NAND block cannot be guaranteed."
    ) -ErrorAction SilentlyContinue

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
} catch {
    Write-Log ("Secure cleanup failed: {0}" -f $_.Exception.Message)
    throw
}
