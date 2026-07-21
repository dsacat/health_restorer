[CmdletBinding()]
param(
    [ValidateSet("Start", "Resume", "RestoreStartup")]
    [string]$Mode = "Start"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Join-Path $env:ProgramData "HealthRestorer"
$ScriptPath = Join-Path $Root "HealthRestorer.ps1"
$StatePath = Join-Path $Root "state.txt"
$LogPath = Join-Path $Root "health-restorer.log"
$BackupPointer = Join-Path $Root "latest-backup.txt"
$DefenderBackupPath = Join-Path $Root "defender-preferences-before-full-scan.json"
$FullScanReportPath = Join-Path $Root "defender-full-scan-report.txt"
$TaskName = "HealthRestorer-OneTime"
$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Test-Admin {
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

function Invoke-Native {
    param(
        [string]$File,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Log ("Running: {0} {1}" -f $File, ($Arguments -join " "))
    $process = Start-Process `
        -FilePath $File `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    Write-Log ("Exit code: {0}" -f $process.ExitCode)

    if ($process.ExitCode -notin $AllowedExitCodes) {
        throw "Command failed: $File, exit code $($process.ExitCode)"
    }

    return $process.ExitCode
}

function Register-ResumeTask {
    $action = New-ScheduledTaskAction -Execute $PowerShell -Argument (
        "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"{0}`" -Mode Resume" -f $ScriptPath
    )
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Days 31)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    Write-Log "Resume task registered."
}

function Remove-ResumeTask {
    Unregister-ScheduledTask `
        -TaskName $TaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    Write-Log "Resume task removed."
}

function Export-And-ClearRegistryValues {
    param(
        [string]$Key,
        [string]$Backup
    )

    $query = Start-Process `
        -FilePath "reg.exe" `
        -ArgumentList @("query", $Key) `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    if ($query.ExitCode -ne 0) {
        return $false
    }

    Invoke-Native "reg.exe" @("export", $Key, $Backup, "/y") | Out-Null
    Invoke-Native "reg.exe" @("delete", $Key, "/va", "/f") | Out-Null
    return $true
}

function Get-UserProfiles {
    return @(Get-CimInstance Win32_UserProfile | Where-Object {
        -not $_.Special -and
        $_.SID -and
        $_.LocalPath -and
        (Test-Path -LiteralPath (Join-Path $_.LocalPath "NTUSER.DAT"))
    })
}

function Disable-Startup {
    $backup = Join-Path $Root (
        "StartupBackup-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
    )
    $registryBackup = Join-Path $backup "registry"
    $filesBackup = Join-Path $backup "startup-files"
    New-Item -ItemType Directory -Path $registryBackup, $filesBackup -Force | Out-Null

    $machineKeys = @(
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce"
    )

    for ($index = 0; $index -lt $machineKeys.Count; $index++) {
        $name = "machine-{0:D2}.reg" -f ($index + 1)
        Export-And-ClearRegistryValues `
            -Key $machineKeys[$index] `
            -Backup (Join-Path $registryBackup $name) | Out-Null
    }

    $profiles = Get-UserProfiles
    $userManifest = @()

    foreach ($profile in $profiles) {
        $sid = [string]$profile.SID
        $hive = "HKU\$sid"
        $providerHive = "Registry::HKEY_USERS\$sid"
        $ntUser = Join-Path $profile.LocalPath "NTUSER.DAT"
        $loadedHere = $false

        if (-not (Test-Path -LiteralPath $providerHive)) {
            $load = Start-Process `
                -FilePath "reg.exe" `
                -ArgumentList @("load", $hive, $ntUser) `
                -Wait `
                -PassThru `
                -WindowStyle Hidden

            if ($load.ExitCode -ne 0) {
                Write-Log ("Could not load profile hive: {0}" -f $profile.LocalPath)
                continue
            }

            $loadedHere = $true
        }

        $safeSid = $sid -replace "[^A-Za-z0-9_-]", "_"
        $files = @()

        try {
            $runFile = Join-Path $registryBackup "user-$safeSid-run.reg"
            $runOnceFile = Join-Path $registryBackup "user-$safeSid-runonce.reg"

            if (Export-And-ClearRegistryValues `
                -Key "$hive\Software\Microsoft\Windows\CurrentVersion\Run" `
                -Backup $runFile) {
                $files += $runFile
            }

            if (Export-And-ClearRegistryValues `
                -Key "$hive\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
                -Backup $runOnceFile) {
                $files += $runOnceFile
            }
        }
        finally {
            if ($loadedHere) {
                Start-Sleep -Milliseconds 500
                Start-Process `
                    -FilePath "reg.exe" `
                    -ArgumentList @("unload", $hive) `
                    -Wait `
                    -WindowStyle Hidden | Out-Null
            }
        }

        if ($files.Count -gt 0) {
            $userManifest += [pscustomobject]@{
                Sid = $sid
                ProfilePath = [string]$profile.LocalPath
                Files = $files
            }
        }
    }

    $userManifest |
        ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $backup "registry-users.json") -Encoding UTF8

    $folderManifest = @()
    $folders = @(
        (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup")
    )
    $folders += $profiles | ForEach-Object {
        Join-Path $_.LocalPath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    }

    $counter = 0
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder)) {
            continue
        }

        Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "desktop.ini" } |
            ForEach-Object {
                $counter++
                $target = Join-Path $filesBackup (
                    "{0:D4}-{1}" -f $counter, $_.Name
                )
                Move-Item -LiteralPath $_.FullName -Destination $target -Force
                $folderManifest += [pscustomobject]@{
                    Original = $_.FullName
                    Backup = $target
                }
            }
    }

    $folderManifest |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $backup "startup-files.json") -Encoding UTF8

    $taskManifest = @()
    Get-ScheduledTask | Where-Object {
        $_.TaskName -ne $TaskName -and
        $_.TaskPath -notlike "\Microsoft\*" -and
        $_.State -ne "Disabled"
    } | ForEach-Object {
        $task = $_
        $autoStart = $false

        foreach ($trigger in $task.Triggers) {
            if ($trigger.CimClass.CimClassName -in @(
                "MSFT_TaskBootTrigger",
                "MSFT_TaskLogonTrigger"
            )) {
                $autoStart = $true
            }
        }

        if ($autoStart) {
            Disable-ScheduledTask `
                -TaskName $task.TaskName `
                -TaskPath $task.TaskPath | Out-Null
            $taskManifest += [pscustomobject]@{
                TaskName = $task.TaskName
                TaskPath = $task.TaskPath
            }
        }
    }

    $taskManifest |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $backup "scheduled-tasks.json") -Encoding UTF8

    Set-Content -LiteralPath $BackupPointer -Value $backup -Encoding UTF8
    Write-Log ("Startup disabled. Backup: {0}" -f $backup)
    return $backup
}

function Restore-Startup {
    if (-not (Test-Path -LiteralPath $BackupPointer)) {
        throw "Startup backup pointer was not found."
    }

    $backup = (Get-Content -LiteralPath $BackupPointer -Raw).Trim()
    if (-not (Test-Path -LiteralPath $backup)) {
        throw "Startup backup was not found."
    }

    Get-ChildItem `
        -LiteralPath (Join-Path $backup "registry") `
        -Filter "machine-*.reg" `
        -ErrorAction SilentlyContinue |
        ForEach-Object {
            Invoke-Native "reg.exe" @("import", $_.FullName) | Out-Null
        }

    $usersFile = Join-Path $backup "registry-users.json"
    if (Test-Path -LiteralPath $usersFile) {
        foreach ($user in @(
            Get-Content -LiteralPath $usersFile -Raw | ConvertFrom-Json
        )) {
            $sid = [string]$user.Sid
            $hive = "HKU\$sid"
            $providerHive = "Registry::HKEY_USERS\$sid"
            $ntUser = Join-Path ([string]$user.ProfilePath) "NTUSER.DAT"
            $loadedHere = $false

            if (-not (Test-Path -LiteralPath $providerHive)) {
                $load = Start-Process `
                    -FilePath "reg.exe" `
                    -ArgumentList @("load", $hive, $ntUser) `
                    -Wait `
                    -PassThru `
                    -WindowStyle Hidden

                if ($load.ExitCode -ne 0) {
                    continue
                }

                $loadedHere = $true
            }

            try {
                foreach ($file in @($user.Files)) {
                    if (Test-Path -LiteralPath $file) {
                        Invoke-Native "reg.exe" @("import", [string]$file) | Out-Null
                    }
                }
            }
            finally {
                if ($loadedHere) {
                    Start-Sleep -Milliseconds 500
                    Start-Process `
                        -FilePath "reg.exe" `
                        -ArgumentList @("unload", $hive) `
                        -Wait `
                        -WindowStyle Hidden | Out-Null
                }
            }
        }
    }

    $filesFile = Join-Path $backup "startup-files.json"
    if (Test-Path -LiteralPath $filesFile) {
        foreach ($entry in @(
            Get-Content -LiteralPath $filesFile -Raw | ConvertFrom-Json
        )) {
            if (Test-Path -LiteralPath $entry.Backup) {
                New-Item `
                    -ItemType Directory `
                    -Path (Split-Path $entry.Original -Parent) `
                    -Force | Out-Null
                Move-Item `
                    -LiteralPath $entry.Backup `
                    -Destination $entry.Original `
                    -Force
            }
        }
    }

    $tasksFile = Join-Path $backup "scheduled-tasks.json"
    if (Test-Path -LiteralPath $tasksFile) {
        foreach ($task in @(
            Get-Content -LiteralPath $tasksFile -Raw | ConvertFrom-Json
        )) {
            Enable-ScheduledTask `
                -TaskName $task.TaskName `
                -TaskPath $task.TaskPath `
                -ErrorAction SilentlyContinue | Out-Null
        }
    }

    Write-Log ("Startup restored from: {0}" -f $backup)
}

function Clear-Folder {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Write-Log ("Cleaning: {0}" -f $Path)
        Get-ChildItem `
            -LiteralPath $Path `
            -Force `
            -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Clear-Junk {
    $services = @("wuauserv", "bits", "DoSvc")
    $wasRunning = @{}

    foreach ($name in $services) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            $wasRunning[$name] = $service.Status -eq "Running"
            if ($service.Status -eq "Running") {
                Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            }
        }
    }

    try {
        Clear-Folder (Join-Path $env:SystemRoot "Temp")
        Clear-Folder (Join-Path $env:SystemRoot "SoftwareDistribution\Download")
        Clear-Folder (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportArchive")
        Clear-Folder (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportQueue")

        Get-UserProfiles | ForEach-Object {
            $local = Join-Path $_.LocalPath "AppData\Local"
            Clear-Folder (Join-Path $local "Temp")
            Clear-Folder (Join-Path $local "D3DSCache")
            Clear-Folder (Join-Path $local "Microsoft\Windows\INetCache")

            $explorer = Join-Path $local "Microsoft\Windows\Explorer"
            if (Test-Path -LiteralPath $explorer) {
                Get-ChildItem `
                    -LiteralPath $explorer `
                    -Filter "thumbcache_*.db" `
                    -Force `
                    -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }

            foreach ($browserRoot in @(
                (Join-Path $local "Google\Chrome\User Data"),
                (Join-Path $local "Microsoft\Edge\User Data")
            )) {
                if (Test-Path -LiteralPath $browserRoot) {
                    Get-ChildItem `
                        -LiteralPath $browserRoot `
                        -Directory `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.Name -in @(
                                "Cache",
                                "Code Cache",
                                "GPUCache",
                                "DawnCache",
                                "GrShaderCache",
                                "ShaderCache"
                            )
                        } |
                        ForEach-Object {
                            Clear-Folder $_.FullName
                        }
                }
            }

            $firefox = Join-Path $local "Mozilla\Firefox\Profiles"
            if (Test-Path -LiteralPath $firefox) {
                Get-ChildItem `
                    -LiteralPath $firefox `
                    -Directory `
                    -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        Clear-Folder (Join-Path $_.FullName "cache2")
                        Clear-Folder (Join-Path $_.FullName "startupCache")
                    }
            }
        }

        if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
            Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
        }

        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    }
    finally {
        foreach ($name in $services) {
            if ($wasRunning.ContainsKey($name) -and $wasRunning[$name]) {
                Start-Service -Name $name -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-MpCmdRunPath {
    $platformRoot = Join-Path $env:ProgramData "Microsoft\Windows Defender\Platform"

    if (Test-Path -LiteralPath $platformRoot) {
        $candidate = Get-ChildItem `
            -LiteralPath $platformRoot `
            -Directory `
            -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object {
                Join-Path $_.FullName "MpCmdRun.exe"
            } |
            Where-Object {
                Test-Path -LiteralPath $_
            } |
            Select-Object -First 1

        if ($candidate) {
            return $candidate
        }
    }

    $fallback = Join-Path $env:ProgramFiles "Windows Defender\MpCmdRun.exe"
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }

    throw "MpCmdRun.exe was not found."
}

function Set-DefenderBooleanPreference {
    param(
        [string]$Name,
        [bool]$Value
    )

    $parameters = @{ ErrorAction = "Stop" }
    $parameters[$Name] = $Value
    Set-MpPreference @parameters
}

function Invoke-FullDefenderScan {
    $status = Get-MpComputerStatus -ErrorAction Stop
    if (-not $status.AntivirusEnabled) {
        throw "Microsoft Defender Antivirus is disabled."
    }

    try {
        Update-MpSignature -ErrorAction Stop
        Write-Log "Defender signatures updated before full scan."
    }
    catch {
        Write-Log (
            "Defender signature update before full scan failed: {0}" -f `
                $_.Exception.Message
        )
    }

    $preference = Get-MpPreference -ErrorAction Stop
    $desiredOptions = [ordered]@{
        DisableArchiveScanning = $false
        DisableEmailScanning = $false
        DisableRemovableDriveScanning = $false
        DisableRestorePoint = $false
        DisableScanningMappedNetworkDrivesForFullScan = $false
        DisableScanningNetworkFiles = $false
        DisableScriptScanning = $false
        CheckForSignaturesBeforeRunningScan = $true
    }
    $savedOptions = [ordered]@{}

    foreach ($name in $desiredOptions.Keys) {
        if ($preference.PSObject.Properties.Name -contains $name) {
            $savedOptions[$name] = [bool]$preference.$name
        }
    }

    $savedExclusions = [ordered]@{
        Path = @($preference.ExclusionPath | Where-Object { $_ })
        Extension = @($preference.ExclusionExtension | Where-Object { $_ })
        Process = @($preference.ExclusionProcess | Where-Object { $_ })
    }

    [pscustomobject]@{
        SavedAt = (Get-Date).ToString("o")
        Options = $savedOptions
        Exclusions = $savedExclusions
    } |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $DefenderBackupPath -Encoding UTF8

    try {
        foreach ($name in $savedOptions.Keys) {
            try {
                Set-DefenderBooleanPreference `
                    -Name $name `
                    -Value ([bool]$desiredOptions[$name])
                Write-Log ("Configured full-scan coverage: {0}" -f $name)
            }
            catch {
                Write-Log (
                    "Could not configure Defender option {0}: {1}" -f `
                        $name, $_.Exception.Message
                )
            }
        }

        foreach ($kind in @("Path", "Extension", "Process")) {
            $values = @($savedExclusions[$kind])
            if ($values.Count -eq 0) {
                continue
            }

            try {
                $parameters = @{ ErrorAction = "Stop" }
                $parameters["Exclusion$kind"] = $values
                Remove-MpPreference @parameters
                Write-Log (
                    "Temporarily removed Defender {0} exclusions: {1}" -f `
                        $kind, $values.Count
                )
            }
            catch {
                Write-Log (
                    "Could not remove Defender {0} exclusions: {1}" -f `
                        $kind, $_.Exception.Message
                )
            }
        }

        $mpCmdRun = Get-MpCmdRunPath
        $started = Get-Date
        Write-Log "Starting mandatory Defender full scan of all accessible files."

        $process = Start-Process `
            -FilePath $mpCmdRun `
            -ArgumentList @("-Scan", "-ScanType", "2", "-Timeout", "30") `
            -Wait `
            -PassThru `
            -WindowStyle Hidden

        $finished = Get-Date
        $detections = Get-MpThreatDetection -ErrorAction SilentlyContinue |
            Select-Object `
                -First 100 `
                InitialDetectionTime, ThreatName, ActionSuccess, Resources

        @(
            "Mandatory Microsoft Defender full scan"
            "Started: $($started.ToString('yyyy-MM-dd HH:mm:ss'))"
            "Finished: $($finished.ToString('yyyy-MM-dd HH:mm:ss'))"
            "Duration: $(($finished - $started).ToString())"
            "Exit code: $($process.ExitCode)"
            ""
            "Recent detections:"
            ($detections | Format-List | Out-String)
        ) | Set-Content -LiteralPath $FullScanReportPath -Encoding UTF8

        if ($process.ExitCode -notin @(0, 2)) {
            throw "Defender full scan failed with exit code $($process.ExitCode)."
        }

        if ($process.ExitCode -eq 2) {
            Write-Log (
                "Full scan completed with malware requiring attention or scan errors."
            )
        }
        else {
            Write-Log "Mandatory Defender full scan completed successfully."
        }
    }
    finally {
        foreach ($kind in @("Path", "Extension", "Process")) {
            $values = @($savedExclusions[$kind])
            if ($values.Count -eq 0) {
                continue
            }

            try {
                $parameters = @{ ErrorAction = "Stop" }
                $parameters["Exclusion$kind"] = $values
                Add-MpPreference @parameters
                Write-Log (
                    "Restored Defender {0} exclusions: {1}" -f `
                        $kind, $values.Count
                )
            }
            catch {
                Write-Log (
                    "Could not restore Defender {0} exclusions: {1}" -f `
                        $kind, $_.Exception.Message
                )
            }
        }

        foreach ($name in $savedOptions.Keys) {
            try {
                Set-DefenderBooleanPreference `
                    -Name $name `
                    -Value ([bool]$savedOptions[$name])
            }
            catch {
                Write-Log (
                    "Could not restore Defender option {0}: {1}" -f `
                        $name, $_.Exception.Message
                )
            }
        }
    }
}

function Repair-And-Optimize {
    Start-Sleep -Seconds 60

    Invoke-Native `
        "dism.exe" `
        @("/Online", "/Cleanup-Image", "/RestoreHealth") `
        @(0, 3010) | Out-Null
    Invoke-Native "sfc.exe" @("/scannow") @(0, 1, 2) | Out-Null
    Invoke-Native `
        "dism.exe" `
        @("/Online", "/Cleanup-Image", "/StartComponentCleanup") `
        @(0, 3010) | Out-Null

    Clear-Junk

    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Where-Object { $_.DeviceID } |
        ForEach-Object {
            Invoke-Native `
                "chkdsk.exe" `
                @($_.DeviceID, "/scan") `
                @(0, 1, 2, 3) | Out-Null
            Invoke-Native `
                "defrag.exe" `
                @($_.DeviceID, "/O", "/U", "/V") `
                @(0) | Out-Null
        }
}

function Write-Report {
    $desktop = Join-Path $env:PUBLIC "Desktop"
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    $report = Join-Path $desktop "HealthRestorer-report.txt"
    $backup = if (Test-Path -LiteralPath $BackupPointer) {
        (Get-Content -LiteralPath $BackupPointer -Raw).Trim()
    }
    else {
        "Not found"
    }
    $fullScan = if (Test-Path -LiteralPath $FullScanReportPath) {
        Get-Content -LiteralPath $FullScanReportPath -Raw
    }
    else {
        "Full scan report was not found."
    }
    $threats = Get-MpThreatDetection -ErrorAction SilentlyContinue |
        Select-Object `
            -First 100 `
            InitialDetectionTime, ThreatName, ActionSuccess, Resources

    @(
        "Health Restorer completed: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "Log: $LogPath"
        "Startup backup: $backup"
        ""
        $fullScan
        ""
        "Recent Microsoft Defender detections:"
        ($threats | Format-List | Out-String)
    ) | Set-Content -LiteralPath $report -Encoding UTF8

    Write-Log ("Report created: {0}" -f $report)
}

function Start-Workflow {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination $ScriptPath -Force
    Register-ResumeTask
    Set-Content -LiteralPath $StatePath -Value "AfterOffline" -Encoding ASCII

    try {
        Update-MpSignature -ErrorAction Stop
        Write-Log "Defender signatures updated."
    }
    catch {
        Write-Log (
            "Defender signature update failed: {0}" -f $_.Exception.Message
        )
    }

    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if (-not $status.AntivirusEnabled) {
            throw "Microsoft Defender Antivirus is disabled."
        }

        Write-Log "Starting Microsoft Defender Offline scan."
        Start-MpWDOScan
        Start-Sleep -Seconds 10
    }
    catch {
        Write-Log (
            "Offline scan could not start: {0}" -f $_.Exception.Message
        )
    }

    Restart-Computer -Force
}

function Resume-Workflow {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        throw "State file was not found."
    }

    $state = (Get-Content -LiteralPath $StatePath -Raw).Trim()

    switch ($state) {
        "AfterOffline" {
            Invoke-FullDefenderScan
            Disable-Startup | Out-Null
            Set-Content -LiteralPath $StatePath -Value "AfterDisk" -Encoding ASCII
            Invoke-Native "chkntfs.exe" @("/c", $env:SystemDrive) | Out-Null
            Invoke-Native `
                "fsutil.exe" `
                @("dirty", "set", $env:SystemDrive) | Out-Null
            Write-Log "Boot-time disk check scheduled."
            Restart-Computer -Force
        }
        "AfterDisk" {
            Set-Content -LiteralPath $StatePath -Value "Maintenance" -Encoding ASCII
            Repair-And-Optimize
            Write-Report
            Set-Content -LiteralPath $StatePath -Value "Completed" -Encoding ASCII
            Remove-ResumeTask
            Write-Log "All stages completed."
        }
        "Maintenance" {
            Repair-And-Optimize
            Write-Report
            Set-Content -LiteralPath $StatePath -Value "Completed" -Encoding ASCII
            Remove-ResumeTask
            Write-Log "Interrupted maintenance resumed and completed."
        }
        "Completed" {
            Remove-ResumeTask
        }
        default {
            throw "Unknown state: $state"
        }
    }
}

if (-not (Test-Admin)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode"
    Start-Process -FilePath $PowerShell -Verb RunAs -ArgumentList $arguments
    exit
}

try {
    switch ($Mode) {
        "Start" {
            Start-Workflow
        }
        "Resume" {
            Resume-Workflow
        }
        "RestoreStartup" {
            Restore-Startup
        }
    }
}
catch {
    Write-Log ("FATAL: {0}" -f $_.Exception.Message)
    throw
}
