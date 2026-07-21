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
$TaskName = "HealthRestorer-OneTime"
$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param([string]$Text)

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value (
        "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    )
}

function Invoke-Process {
    param(
        [string]$File,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Log ("Running: {0} {1}" -f $File, ($Arguments -join " "))
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
    Write-Log ("Exit code: {0}" -f $process.ExitCode)

    if ($process.ExitCode -notin $AllowedExitCodes) {
        throw "Command failed: $File, exit code $($process.ExitCode)"
    }
}

function Register-ResumeTask {
    $action = New-ScheduledTaskAction -Execute $PowerShell -Argument (
        "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"{0}`" -Mode Resume" -f $ScriptPath
    )
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 24)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Resume task registered."
}

function Remove-ResumeTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Resume task removed."
}

function Export-And-ClearKey {
    param(
        [string]$Key,
        [string]$Backup
    )

    $query = Start-Process -FilePath "reg.exe" -ArgumentList @("query", $Key) -Wait -PassThru -WindowStyle Hidden
    if ($query.ExitCode -ne 0) {
        return $false
    }

    Invoke-Process "reg.exe" @("export", $Key, $Backup, "/y")
    Invoke-Process "reg.exe" @("delete", $Key, "/va", "/f")
    return $true
}

function Disable-Startup {
    $backup = Join-Path $Root ("StartupBackup-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $registryBackup = Join-Path $backup "registry"
    $filesBackup = Join-Path $backup "startup-files"
    New-Item -ItemType Directory -Path $registryBackup, $filesBackup -Force | Out-Null

    $machineKeys = @(
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce"
    )

    $index = 0
    foreach ($key in $machineKeys) {
        $index++
        Export-And-ClearKey $key (Join-Path $registryBackup "machine-$index.reg") | Out-Null
    }

    $userManifest = @()
    $profiles = Get-CimInstance Win32_UserProfile | Where-Object {
        -not $_.Special -and $_.SID -and $_.LocalPath -and (Test-Path (Join-Path $_.LocalPath "NTUSER.DAT"))
    }

    foreach ($profile in $profiles) {
        $sid = [string]$profile.SID
        $hive = "HKU\$sid"
        $providerHive = "Registry::HKEY_USERS\$sid"
        $loadedHere = $false
        $ntUser = Join-Path $profile.LocalPath "NTUSER.DAT"

        if (-not (Test-Path $providerHive)) {
            $load = Start-Process -FilePath "reg.exe" -ArgumentList @("load", $hive, $ntUser) -Wait -PassThru -WindowStyle Hidden
            if ($load.ExitCode -ne 0) {
                Write-Log ("Could not load user profile: {0}" -f $profile.LocalPath)
                continue
            }
            $loadedHere = $true
        }

        $safeSid = $sid -replace "[^A-Za-z0-9_-]", "_"
        $saved = @()

        try {
            $run = Join-Path $registryBackup "user-$safeSid-run.reg"
            $runOnce = Join-Path $registryBackup "user-$safeSid-runonce.reg"

            if (Export-And-ClearKey "$hive\Software\Microsoft\Windows\CurrentVersion\Run" $run) {
                $saved += $run
            }
            if (Export-And-ClearKey "$hive\Software\Microsoft\Windows\CurrentVersion\RunOnce" $runOnce) {
                $saved += $runOnce
            }
        }
        finally {
            if ($loadedHere) {
                Start-Sleep -Milliseconds 500
                Start-Process -FilePath "reg.exe" -ArgumentList @("unload", $hive) -Wait -WindowStyle Hidden | Out-Null
            }
        }

        if ($saved.Count -gt 0) {
            $userManifest += [pscustomobject]@{
                Sid = $sid
                ProfilePath = [string]$profile.LocalPath
                Files = $saved
            }
        }
    }

    $userManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backup "registry-users.json") -Encoding UTF8

    $folderManifest = @()
    $folders = @(
        (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup")
    )
    $folders += $profiles | ForEach-Object {
        Join-Path $_.LocalPath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    }

    $counter = 0
    foreach ($folder in $folders) {
        if (-not (Test-Path $folder)) {
            continue
        }

        Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "desktop.ini" } |
            ForEach-Object {
                $counter++
                $target = Join-Path $filesBackup ("{0:D4}-{1}" -f $counter, $_.Name)
                Move-Item -LiteralPath $_.FullName -Destination $target -Force
                $folderManifest += [pscustomobject]@{
                    Original = $_.FullName
                    Backup = $target
                }
            }
    }

    $folderManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup "startup-files.json") -Encoding UTF8

    $taskManifest = @()
    Get-ScheduledTask | Where-Object {
        $_.TaskName -ne $TaskName -and $_.TaskPath -notlike "\Microsoft\*" -and $_.State -ne "Disabled"
    } | ForEach-Object {
        $task = $_
        $startsAutomatically = $false

        foreach ($trigger in $task.Triggers) {
            if ($trigger.CimClass.CimClassName -in @("MSFT_TaskBootTrigger", "MSFT_TaskLogonTrigger")) {
                $startsAutomatically = $true
            }
        }

        if ($startsAutomatically) {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
            $taskManifest += [pscustomobject]@{
                TaskName = $task.TaskName
                TaskPath = $task.TaskPath
            }
        }
    }

    $taskManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup "scheduled-tasks.json") -Encoding UTF8
    Set-Content -LiteralPath $BackupPointer -Value $backup -Encoding UTF8
    Write-Log ("Startup disabled. Backup: {0}" -f $backup)
    return $backup
}

function Restore-Startup {
    if (-not (Test-Path $BackupPointer)) {
        throw "Startup backup pointer was not found."
    }

    $backup = (Get-Content -LiteralPath $BackupPointer -Raw).Trim()
    if (-not (Test-Path $backup)) {
        throw "Startup backup was not found."
    }

    Get-ChildItem -LiteralPath (Join-Path $backup "registry") -Filter "machine-*.reg" -ErrorAction SilentlyContinue |
        ForEach-Object { Invoke-Process "reg.exe" @("import", $_.FullName) }

    $usersFile = Join-Path $backup "registry-users.json"
    if (Test-Path $usersFile) {
        foreach ($user in @((Get-Content -LiteralPath $usersFile -Raw | ConvertFrom-Json))) {
            $sid = [string]$user.Sid
            $hive = "HKU\$sid"
            $providerHive = "Registry::HKEY_USERS\$sid"
            $loadedHere = $false
            $ntUser = Join-Path ([string]$user.ProfilePath) "NTUSER.DAT"

            if (-not (Test-Path $providerHive)) {
                $load = Start-Process -FilePath "reg.exe" -ArgumentList @("load", $hive, $ntUser) -Wait -PassThru -WindowStyle Hidden
                if ($load.ExitCode -ne 0) {
                    continue
                }
                $loadedHere = $true
            }

            try {
                foreach ($file in @($user.Files)) {
                    if (Test-Path $file) {
                        Invoke-Process "reg.exe" @("import", [string]$file)
                    }
                }
            }
            finally {
                if ($loadedHere) {
                    Start-Sleep -Milliseconds 500
                    Start-Process -FilePath "reg.exe" -ArgumentList @("unload", $hive) -Wait -WindowStyle Hidden | Out-Null
                }
            }
        }
    }

    $filesFile = Join-Path $backup "startup-files.json"
    if (Test-Path $filesFile) {
        foreach ($entry in @((Get-Content -LiteralPath $filesFile -Raw | ConvertFrom-Json))) {
            if (Test-Path $entry.Backup) {
                New-Item -ItemType Directory -Path (Split-Path $entry.Original -Parent) -Force | Out-Null
                Move-Item -LiteralPath $entry.Backup -Destination $entry.Original -Force
            }
        }
    }

    $tasksFile = Join-Path $backup "scheduled-tasks.json"
    if (Test-Path $tasksFile) {
        foreach ($task in @((Get-Content -LiteralPath $tasksFile -Raw | ConvertFrom-Json))) {
            Enable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
        }
    }

    Write-Log ("Startup restored from: {0}" -f $backup)
}

function Clear-Folder {
    param([string]$Path)

    if (Test-Path $Path) {
        Write-Log ("Cleaning: {0}" -f $Path)
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
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

    Clear-Folder (Join-Path $env:SystemRoot "Temp")
    Clear-Folder (Join-Path $env:SystemRoot "SoftwareDistribution\Download")
    Clear-Folder (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportArchive")
    Clear-Folder (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportQueue")

    Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath } | ForEach-Object {
        $local = Join-Path $_.LocalPath "AppData\Local"
        Clear-Folder (Join-Path $local "Temp")
        Clear-Folder (Join-Path $local "D3DSCache")
        Clear-Folder (Join-Path $local "Microsoft\Windows\INetCache")

        foreach ($root in @(
            (Join-Path $local "Google\Chrome\User Data"),
            (Join-Path $local "Microsoft\Edge\User Data")
        )) {
            if (Test-Path $root) {
                Get-ChildItem -LiteralPath $root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -in @("Cache", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "ShaderCache") } |
                    ForEach-Object { Clear-Folder $_.FullName }
            }
        }

        $firefox = Join-Path $local "Mozilla\Firefox\Profiles"
        if (Test-Path $firefox) {
            Get-ChildItem -LiteralPath $firefox -Directory -ErrorAction SilentlyContinue | ForEach-Object {
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

    foreach ($name in $services) {
        if ($wasRunning.ContainsKey($name) -and $wasRunning[$name]) {
            Start-Service -Name $name -ErrorAction SilentlyContinue
        }
    }
}

function Repair-And-Optimize {
    Start-Sleep -Seconds 60

    Invoke-Process "dism.exe" @("/Online", "/Cleanup-Image", "/RestoreHealth") @(0, 3010)
    Invoke-Process "sfc.exe" @("/scannow") @(0, 1, 2)
    Invoke-Process "dism.exe" @("/Online", "/Cleanup-Image", "/StartComponentCleanup") @(0, 3010)

    Clear-Junk

    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Where-Object { $_.DeviceID } | ForEach-Object {
        Invoke-Process "chkdsk.exe" @($_.DeviceID, "/scan") @(0, 1, 2, 3)
        Invoke-Process "defrag.exe" @($_.DeviceID, "/O", "/U", "/V") @(0)
    }
}

function Write-Report {
    $desktop = Join-Path $env:PUBLIC "Desktop"
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    $report = Join-Path $desktop "HealthRestorer-report.txt"
    $backup = if (Test-Path $BackupPointer) { (Get-Content -LiteralPath $BackupPointer -Raw).Trim() } else { "Not found" }
    $threats = Get-MpThreatDetection -ErrorAction SilentlyContinue | Select-Object -First 50 InitialDetectionTime, ThreatName, ActionSuccess, Resources

    @(
        "Health Restorer completed: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "Log: $LogPath"
        "Startup backup: $backup"
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
    Set-Content -LiteralPath $StatePath -Value "AfterDefender" -Encoding ASCII

    try {
        Update-MpSignature -ErrorAction Stop
        Write-Log "Defender signatures updated."
    }
    catch {
        Write-Log ("Defender signature update failed: {0}" -f $_.Exception.Message)
    }

    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if (-not $status.AntivirusEnabled) {
            throw "Microsoft Defender Antivirus is disabled."
        }

        Write-Log "Starting Microsoft Defender Offline scan."
        Start-MpWDOScan
    }
    catch {
        Write-Log ("Offline scan could not start: {0}" -f $_.Exception.Message)
        try {
            Start-MpScan -ScanType FullScan -ErrorAction Stop
        }
        catch {
            Write-Log ("Fallback full scan failed: {0}" -f $_.Exception.Message)
        }
        Restart-Computer -Force
    }
}

function Resume-Workflow {
    if (-not (Test-Path $StatePath)) {
        throw "State file was not found."
    }

    $state = (Get-Content -LiteralPath $StatePath -Raw).Trim()

    switch ($state) {
        "AfterDefender" {
            Disable-Startup | Out-Null
            Set-Content -LiteralPath $StatePath -Value "AfterDisk" -Encoding ASCII
            Invoke-Process "chkntfs.exe" @("/c", $env:SystemDrive)
            Invoke-Process "fsutil.exe" @("dirty", "set", $env:SystemDrive)
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
        "Start" { Start-Workflow }
        "Resume" { Resume-Workflow }
        "RestoreStartup" { Restore-Startup }
    }
}
catch {
    Write-Log ("FATAL: {0}" -f $_.Exception.Message)
    throw
}
