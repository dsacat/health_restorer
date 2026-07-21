[CmdletBinding()]
param(
    [string]$ReportPath = (Join-Path $env:ProgramData "HealthRestorer\autorun-audit.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Join-Path $env:ProgramData "HealthRestorer"
$LogPath = Join-Path $Root "health-restorer.log"

function Write-Log {
    param([string]$Text)

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value (
        "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    )
}

function Get-ValueText {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [array]) {
        return ($Value -join "; ")
    }

    return [string]$Value
}

function Get-RegistryValues {
    param(
        [string]$ProviderPath,
        [string]$Category,
        [string[]]$OnlyNames = @()
    )

    $result = @()
    if (-not (Test-Path -LiteralPath $ProviderPath)) {
        return $result
    }

    try {
        $item = Get-ItemProperty -LiteralPath $ProviderPath -ErrorAction Stop
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -match '^PS(Path|ParentPath|ChildName|Drive|Provider)$') {
                continue
            }

            if ($OnlyNames.Count -gt 0 -and $property.Name -notin $OnlyNames) {
                continue
            }

            $result += [pscustomobject]@{
                Category = $Category
                Source = $ProviderPath
                Name = $property.Name
                Command = Get-ValueText $property.Value
            }
        }
    }
    catch {
        Write-Log ("Autorun registry audit failed for {0}: {1}" -f $ProviderPath, $_.Exception.Message)
    }

    return $result
}

function Get-RegistrySubkeyValues {
    param(
        [string]$ProviderPath,
        [string]$Category,
        [string[]]$OnlyNames
    )

    $result = @()
    if (-not (Test-Path -LiteralPath $ProviderPath)) {
        return $result
    }

    foreach ($key in Get-ChildItem -LiteralPath $ProviderPath -ErrorAction SilentlyContinue) {
        $result += Get-RegistryValues `
            -ProviderPath $key.PSPath `
            -Category $Category `
            -OnlyNames $OnlyNames
    }

    return $result
}

function Get-StartupFolders {
    $folders = @(
        (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup")
    )

    $commonShellFolders = @(
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
    )

    foreach ($key in $commonShellFolders) {
        try {
            $value = (Get-ItemProperty -LiteralPath $key -Name "Common Startup" -ErrorAction Stop)."Common Startup"
            if ($value) {
                $folders += [Environment]::ExpandEnvironmentVariables([string]$value)
            }
        }
        catch {
        }
    }

    $profiles = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {
        -not $_.Special -and $_.SID -and $_.LocalPath
    }

    foreach ($profile in $profiles) {
        $folders += Join-Path $profile.LocalPath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"

        $sid = [string]$profile.SID
        $hive = "HKU\$sid"
        $providerHive = "Registry::HKEY_USERS\$sid"
        $ntUser = Join-Path $profile.LocalPath "NTUSER.DAT"
        $loadedHere = $false

        if (-not (Test-Path -LiteralPath $providerHive) -and (Test-Path -LiteralPath $ntUser)) {
            $process = Start-Process `
                -FilePath "reg.exe" `
                -ArgumentList @("load", $hive, $ntUser) `
                -Wait `
                -PassThru `
                -WindowStyle Hidden

            if ($process.ExitCode -eq 0) {
                $loadedHere = $true
            }
        }

        try {
            foreach ($relative in @(
                "Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
                "Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
            )) {
                $path = "Registry::HKEY_USERS\$sid\$relative"
                try {
                    $value = (Get-ItemProperty -LiteralPath $path -Name "Startup" -ErrorAction Stop).Startup
                    if ($value) {
                        $expanded = [Environment]::ExpandEnvironmentVariables([string]$value)
                        $expanded = $expanded -replace '^%USERPROFILE%', [string]$profile.LocalPath
                        $folders += $expanded
                    }
                }
                catch {
                }
            }
        }
        finally {
            if ($loadedHere) {
                Start-Sleep -Milliseconds 300
                Start-Process `
                    -FilePath "reg.exe" `
                    -ArgumentList @("unload", $hive) `
                    -Wait `
                    -WindowStyle Hidden | Out-Null
            }
        }
    }

    return @($folders | Where-Object { $_ } | Select-Object -Unique)
}

function Get-StartupFolderEntries {
    $result = @()

    foreach ($folder in Get-StartupFolders) {
        if (-not (Test-Path -LiteralPath $folder)) {
            continue
        }

        foreach ($item in Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue) {
            if ($item.Name -eq "desktop.ini") {
                continue
            }

            $result += [pscustomobject]@{
                Category = "StartupFolder"
                Source = $folder
                Name = $item.Name
                Command = $item.FullName
            }
        }
    }

    return $result
}

function Get-RegistryAutoruns {
    $result = @()
    $directKeys = @(
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Category = "MachineRun" },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"; Category = "MachineRunOnce" },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Category = "MachineRun32" },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce"; Category = "MachineRunOnce32" },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run"; Category = "MachinePolicyRun" },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Command Processor"; Category = "MachineCommandProcessor"; Names = @("AutoRun") },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"; Category = "AppInit"; Names = @("AppInit_DLLs", "LoadAppInit_DLLs") },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"; Category = "Winlogon"; Names = @("Shell", "Userinit", "Taskman", "VmApplet") },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\AppCertDlls"; Category = "AppCertDlls" },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\ShellServiceObjectDelayLoad"; Category = "ShellServiceObjectDelayLoad" },
        @{ Path = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellExecuteHooks"; Category = "ShellExecuteHooks" }
    )

    foreach ($entry in $directKeys) {
        $names = if ($entry.ContainsKey("Names")) { [string[]]$entry.Names } else { @() }
        $result += Get-RegistryValues `
            -ProviderPath $entry.Path `
            -Category $entry.Category `
            -OnlyNames $names
    }

    $result += Get-RegistrySubkeyValues `
        -ProviderPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options" `
        -Category "IFEO" `
        -OnlyNames @("Debugger", "GlobalFlag", "VerifierDlls")

    $result += Get-RegistrySubkeyValues `
        -ProviderPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SilentProcessExit" `
        -Category "SilentProcessExit" `
        -OnlyNames @("MonitorProcess")

    $result += Get-RegistrySubkeyValues `
        -ProviderPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Active Setup\Installed Components" `
        -Category "ActiveSetup" `
        -OnlyNames @("StubPath")

    $profiles = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {
        -not $_.Special -and $_.SID -and $_.LocalPath
    }

    foreach ($profile in $profiles) {
        $sid = [string]$profile.SID
        $hive = "HKU\$sid"
        $providerHive = "Registry::HKEY_USERS\$sid"
        $ntUser = Join-Path $profile.LocalPath "NTUSER.DAT"
        $loadedHere = $false

        if (-not (Test-Path -LiteralPath $providerHive) -and (Test-Path -LiteralPath $ntUser)) {
            $process = Start-Process `
                -FilePath "reg.exe" `
                -ArgumentList @("load", $hive, $ntUser) `
                -Wait `
                -PassThru `
                -WindowStyle Hidden

            if ($process.ExitCode -eq 0) {
                $loadedHere = $true
            }
        }

        try {
            $userKeys = @(
                @{ Relative = "Software\Microsoft\Windows\CurrentVersion\Run"; Category = "UserRun" },
                @{ Relative = "Software\Microsoft\Windows\CurrentVersion\RunOnce"; Category = "UserRunOnce" },
                @{ Relative = "Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run"; Category = "UserPolicyRun" },
                @{ Relative = "Software\Microsoft\Windows NT\CurrentVersion\Windows"; Category = "UserWindowsLoadRun"; Names = @("Load", "Run") },
                @{ Relative = "Software\Microsoft\Command Processor"; Category = "UserCommandProcessor"; Names = @("AutoRun") }
            )

            foreach ($entry in $userKeys) {
                $names = if ($entry.ContainsKey("Names")) { [string[]]$entry.Names } else { @() }
                $items = Get-RegistryValues `
                    -ProviderPath "Registry::HKEY_USERS\$sid\$($entry.Relative)" `
                    -Category $entry.Category `
                    -OnlyNames $names

                foreach ($item in $items) {
                    $item.Source = "$($item.Source) [$($profile.LocalPath)]"
                    $result += $item
                }
            }
        }
        finally {
            if ($loadedHere) {
                Start-Sleep -Milliseconds 300
                Start-Process `
                    -FilePath "reg.exe" `
                    -ArgumentList @("unload", $hive) `
                    -Wait `
                    -WindowStyle Hidden | Out-Null
            }
        }
    }

    return $result
}

function Get-TaskAutoruns {
    $result = @()

    foreach ($task in Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $automatic = @($task.Triggers | Where-Object {
            $_.CimClass.CimClassName -in @(
                "MSFT_TaskBootTrigger",
                "MSFT_TaskLogonTrigger",
                "MSFT_TaskRegistrationTrigger",
                "MSFT_TaskSessionStateChangeTrigger"
            )
        })

        if ($automatic.Count -eq 0) {
            continue
        }

        $commands = @($task.Actions | ForEach-Object {
            if ($_.CimClass.CimClassName -eq "MSFT_TaskExecAction") {
                "{0} {1}" -f $_.Execute, $_.Arguments
            }
            else {
                $_.CimClass.CimClassName
            }
        })

        $result += [pscustomobject]@{
            Category = "ScheduledTask"
            Source = "$($task.TaskPath)$($task.TaskName)"
            Name = $task.State
            Command = $commands -join "; "
        }
    }

    return $result
}

function Get-ServiceAutoruns {
    $result = @()

    foreach ($service in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.StartMode -eq "Auto"
    }) {
        $result += [pscustomobject]@{
            Category = "AutoService"
            Source = [string]$service.Name
            Name = [string]$service.DisplayName
            Command = [string]$service.PathName
        }
    }

    foreach ($driver in Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object {
        $_.StartMode -in @("Boot", "System", "Auto")
    }) {
        $result += [pscustomobject]@{
            Category = "BootOrAutoDriver"
            Source = [string]$driver.Name
            Name = [string]$driver.DisplayName
            Command = [string]$driver.PathName
        }
    }

    return $result
}

function Get-WmiAutoruns {
    $result = @()

    try {
        $filters = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -ErrorAction Stop
        foreach ($filter in $filters) {
            $result += [pscustomobject]@{
                Category = "WmiEventFilter"
                Source = [string]$filter.Name
                Name = [string]$filter.EventNamespace
                Command = [string]$filter.Query
            }
        }

        foreach ($consumer in Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -ErrorAction SilentlyContinue) {
            $result += [pscustomobject]@{
                Category = "WmiCommandConsumer"
                Source = [string]$consumer.Name
                Name = [string]$consumer.ExecutablePath
                Command = [string]$consumer.CommandLineTemplate
            }
        }

        foreach ($consumer in Get-CimInstance -Namespace root\subscription -ClassName ActiveScriptEventConsumer -ErrorAction SilentlyContinue) {
            $result += [pscustomobject]@{
                Category = "WmiScriptConsumer"
                Source = [string]$consumer.Name
                Name = [string]$consumer.ScriptingEngine
                Command = [string]$consumer.ScriptText
            }
        }

        foreach ($binding in Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -ErrorAction SilentlyContinue) {
            $result += [pscustomobject]@{
                Category = "WmiBinding"
                Source = [string]$binding.Filter
                Name = "FilterToConsumerBinding"
                Command = [string]$binding.Consumer
            }
        }
    }
    catch {
        Write-Log ("WMI autorun audit failed: {0}" -f $_.Exception.Message)
    }

    return $result
}

New-Item -ItemType Directory -Path (Split-Path $ReportPath -Parent) -Force | Out-Null

$items = @()
$items += Get-StartupFolderEntries
$items += Get-RegistryAutoruns
$items += Get-TaskAutoruns
$items += Get-ServiceAutoruns
$items += Get-WmiAutoruns

try {
    $items += Get-CimInstance Win32_StartupCommand -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            Category = "Win32StartupCommand"
            Source = [string]$_.Location
            Name = [string]$_.Name
            Command = [string]$_.Command
        }
    }
}
catch {
    Write-Log ("Win32_StartupCommand audit failed: {0}" -f $_.Exception.Message)
}

[pscustomobject]@{
    GeneratedAt = (Get-Date).ToString("o")
    Computer = $env:COMPUTERNAME
    Count = $items.Count
    Items = @($items | Sort-Object Category, Source, Name)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Log ("Comprehensive autorun audit completed. Entries: {0}. Report: {1}" -f $items.Count, $ReportPath)
