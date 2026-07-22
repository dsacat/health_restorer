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
$TaskPath = "\Microsoft\HealthRestorer\"
$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$ResidueScript = Join-Path $Root "ProgramResidueCleanup.ps1"
$ResidueSummaryPath = Join-Path $Root "program-residue-summary.json"
$DeletedDataSummaryPath = Join-Path $Root "deleted-data-summary.json"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param([string]$Text)

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value (
        "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    )
}

function Test-MainWorkflowReadyForCleanup {
    if (Test-Path -LiteralPath $StateJsonPath) {
        try {
            $state = Get-Content -LiteralPath $StateJsonPath -Raw | ConvertFrom-Json
            if ([string]$state.Stage -eq "CleanupPending") {
                return $true
            }
        }
        catch {
            Write-Log ("Could not read state.json: {0}" -f $_.Exception.Message)
        }
    }

    if (Test-Path -LiteralPath $StateTextPath) {
        try {
            if ((Get-Content -LiteralPath $StateTextPath -Raw).Trim() -eq "CleanupPending") {
                return $true
            }
        }
        catch {
            Write-Log ("Could not read state.txt: {0}" -f $_.Exception.Message)
        }
    }

    return $false
}

function Invoke-ProgramResidueCleanup {
    if (-not (Test-Path -LiteralPath $ResidueScript)) {
        throw "Program residue cleanup script was not found: $ResidueScript"
    }

    Remove-Item -LiteralPath $ResidueSummaryPath -Force -ErrorAction SilentlyContinue
    $process = Start-Process `
        -FilePath $PowerShell `
        -ArgumentList @(
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", $ResidueScript,
            "-SummaryPath", $ResidueSummaryPath
        ) `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

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

        if ($disk.BusType -contains "NVMe") {
            return "SSD"
        }

        $physical = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object {
            $_.DeviceId -eq [string]$disk.Number -or
            $_.FriendlyName -eq $disk.FriendlyName
        } | Select-Object -First 1

        if ($null -ne $physical) {
            if ([string]$physical.MediaType -eq "SSD") {
                return "SSD"
            }
            if ([string]$physical.MediaType -eq "HDD") {
                return "HDD"
            }
        }

        $description = "{0} {1} {2}" -f $disk.FriendlyName, $disk.Model, $disk.BusType
        if ($description -match "(?i)SSD|NVMe|Solid State|Flash") {
            return "SSD"
        }
        if ($description -match "(?i)HDD|Hard Disk|Rotational") {
            return "HDD"
        }
    }
    catch {
        Write-Log (
            "Could not identify media type for {0}: {1}" -f `
                $DriveLetter, $_.Exception.Message
        )
    }

    return "Unknown"
}

function Test-VolumeWritable {
    param([Parameter(Mandatory)][string]$DriveRoot)

    $testFile = Join-Path $DriveRoot (
        ".health-restorer-write-test-{0}.tmp" -f [guid]::NewGuid().ToString("N")
    )

    try {
        [IO.File]::WriteAllBytes($testFile, [byte[]]@())
        return $true
    }
    catch {
        Write-Log ("Volume is not writable: {0}. {1}" -f $DriveRoot, $_.Exception.Message)
        return $false
    }
    finally {
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ReTrim {
    param([Parameter(Mandatory)][string]$DriveLetter)

    Write-Log ("Running TRIM/ReTrim on {0}:" -f $DriveLetter)
    Optimize-Volume `
        -DriveLetter $DriveLetter `
        -ReTrim `
        -Verbose `
        -ErrorAction Stop 4>&1 |
        ForEach-Object {
            Write-Log ([string]$_)
        }
}

function Invoke-FreeSpaceOverwriteNtfs {
    param([Parameter(Mandatory)][string]$DriveRoot)

    Write-Log ("Overwriting NTFS free space on {0} with cipher /w." -f $DriveRoot)
    $process = Start-Process `
        -FilePath "cipher.exe" `
        -ArgumentList @("/w:$DriveRoot") `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    Write-Log (
        "cipher /w exit code for {0}: {1}" -f $DriveRoot, $process.ExitCode
    )

    if ($process.ExitCode -ne 0) {
        throw "cipher /w failed for $DriveRoot with exit code $($process.ExitCode)."
    }
}

function Invoke-FreeSpaceOverwriteGeneric {
    param([Parameter(Mandatory)][string]$DriveRoot)

    $wipeFile = Join-Path $DriveRoot (
        ".health-restorer-free-space-wipe-{0}.tmp" -f [guid]::NewGuid().ToString("N")
    )
    $buffer = New-Object byte[] (8MB)
    $stream = $null

    Write-Log (
        "Overwriting free space on non-NTFS HDD volume {0} with a temporary zero-filled file." -f `
            $DriveRoot
    )

    try {
        $stream = New-Object IO.FileStream(
            $wipeFile,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            8MB,
            [IO.FileOptions]::WriteThrough
        )

        while ($true) {
            try {
                $stream.Write($buffer, 0, $buffer.Length)
            }
            catch [IO.IOException] {
                break
            }
        }

        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        Remove-Item -LiteralPath $wipeFile -Force -ErrorAction SilentlyContinue
    }

    Write-Log ("Generic free-space overwrite completed for {0}." -f $DriveRoot)
}

function Get-AccessibleVolumes {
    return @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object {
        $_.DeviceID -and
        $_.FileSystem -and
        $_.DriveType -in @(2, 3)
    } | Sort-Object DeviceID)
}

function Clear-DeletedData {
    $results = @()

    foreach ($volume in Get-AccessibleVolumes) {
        $letter = $volume.DeviceID.TrimEnd(":")
        $driveRoot = "{0}:\" -f $letter
        $fileSystem = [string]$volume.FileSystem
        $kind = Get-VolumeMediaKind $letter
        $status = "Skipped"
        $method = "None"
        $message = $null

        Write-Log (
            "Deleted-data cleanup for {0}. Type: {1}; filesystem: {2}; drive type: {3}." -f `
                $driveRoot, $kind, $fileSystem, $volume.DriveType
        )

        try {
            if (-not (Test-VolumeWritable $driveRoot)) {
                throw "Volume is read-only, locked, or inaccessible."
            }

            switch ($kind) {
                "HDD" {
                    if ($fileSystem -eq "NTFS") {
                        Invoke-FreeSpaceOverwriteNtfs $driveRoot
                        $method = "cipher /w"
                    }
                    else {
                        Invoke-FreeSpaceOverwriteGeneric $driveRoot
                        $method = "zero-fill free space"
                    }
                    $status = "Completed"
                }
                "SSD" {
                    Invoke-ReTrim $letter
                    $method = "TRIM/ReTrim"
                    $status = "Completed"
                    Write-Log (
                        "SSD note: TRIM was issued, but physical overwrite of every NAND block cannot be guaranteed."
                    )
                }
                default {
                    $method = "TRIM/ReTrim attempt"
                    try {
                        Invoke-ReTrim $letter
                        $status = "Completed"
                        $message = "Media type was unknown; ReTrim was used to avoid wearing a possible SSD."
                    }
                    catch {
                        $status = "Skipped"
                        $message = (
                            "Media type was unknown and ReTrim was not supported: {0}" -f `
                                $_.Exception.Message
                        )
                        Write-Log $message
                    }
                }
            }
        }
        catch {
            $status = "Failed"
            $message = $_.Exception.Message
            Write-Log (
                "Deleted-data cleanup failed for {0}: {1}" -f `
                    $driveRoot, $message
            )
        }

        $results += [pscustomobject]@{
            Drive = $driveRoot
            DriveType = [int]$volume.DriveType
            FileSystem = $fileSystem
            MediaKind = $kind
            Method = $method
            Status = $status
            Message = $message
        }
    }

    [pscustomobject]@{
        CompletedAt = (Get-Date).ToString("o")
        Volumes = $results
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $DeletedDataSummaryPath -Encoding UTF8

    return $results
}

if (-not (Test-Administrator)) {
    Start-Process `
        -FilePath $PowerShell `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode"
    exit
}

try {
    if ($Mode -eq "WaitAndClean") {
        Write-Log "Secure cleanup is waiting for main maintenance to reach CleanupPending."
        $deadline = (Get-Date).AddDays(31)

        while (-not (Test-MainWorkflowReadyForCleanup)) {
            if ((Get-Date) -ge $deadline) {
                throw "The main workflow did not reach CleanupPending state within 31 days."
            }
            Start-Sleep -Seconds 60
        }

        Start-Sleep -Seconds 30
    }

    $residue = Invoke-ProgramResidueCleanup
    $deletedData = @(Clear-DeletedData)
    Write-Log "Program residue and deleted-data cleanup completed."
        Set-Content -LiteralPath $StateTextPath -Value "FinalScanPending" -Encoding ASCII
        Write-Log "Final cleanup confirmed. State changed to FinalScanPending; the full scan can now run as the last stage."


    Unregister-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
}
catch {
    Write-Log ("Secure cleanup failed: {0}" -f $_.Exception.Message)
    throw
}
