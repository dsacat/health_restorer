[CmdletBinding()]
param([Parameter(Mandatory)][string]$SummaryPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Join-Path $env:ProgramData "HealthRestorer"
$LogPath = Join-Path $Root "health-restorer.log"
$Backup = Join-Path $Root ("ProgramResidueBackup-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Write-Log {
    param([string]$Text)
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text)
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ExePath {
    param([AllowNull()][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $value = [Environment]::ExpandEnvironmentVariables($Command.Trim()) -replace '^\\\?\?\\', ''
    if ($value -match '^"(?<p>[^"]+\.exe)"') { $path = $Matches.p }
    elseif ($value -match '^(?<p>.+?\.exe)(?:\s|$)') { $path = $Matches.p.Trim('"') }
    else { return $null }
    if ($path -match '^\\SystemRoot\\') { $path = Join-Path $env:SystemRoot $path.Substring(12) }
    elseif ($path -match '^System32\\') { $path = Join-Path $env:SystemRoot $path }
    if (-not [IO.Path]::IsPathRooted($path)) { return $null }
    try { return [IO.Path]::GetFullPath($path) } catch { return $null }
}

function Get-SafeName {
    param([string]$Name)
    $value = ($Name -replace '[^A-Za-zА-Яа-я0-9._-]', '_').Trim('_')
    if ($value.Length -gt 80) { $value = $value.Substring(0, 80) }
    if ([string]::IsNullOrWhiteSpace($value)) { return "item" }
    return $value
}

function Export-Key {
    param([string]$Key, [string]$File)
    New-Item -ItemType Directory -Path (Split-Path $File -Parent) -Force | Out-Null
    $process = Start-Process "reg.exe" -ArgumentList @("export", $Key, $File, "/y") -Wait -PassThru -WindowStyle Hidden
    return $process.ExitCode -eq 0
}

function Test-ResidueFolder {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($full.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $roots = @([Environment]::GetFolderPath("ProgramFiles"), [Environment]::GetFolderPath("ProgramFilesX86"), $env:ProgramData, (Join-Path $env:SystemDrive "Users")) | Where-Object { $_ }
    $allowed = $false
    foreach ($base in $roots) {
        $base = [IO.Path]::GetFullPath($base).TrimEnd('\')
        if ($full.Length -gt $base.Length -and $full.StartsWith($base + "\", [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
    }
    if (-not $allowed) { return $false }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $extensions = @(".exe", ".dll", ".sys", ".com", ".bat", ".cmd", ".ps1", ".msi", ".msix", ".appx", ".jar", ".py", ".pyw", ".vbs", ".js")
    $runnable = Get-ChildItem -LiteralPath $full -File -Recurse -Depth 8 -Force -ErrorAction SilentlyContinue | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 1
    return $null -eq $runnable
}

function Remove-UninstallResidue {
    $entries = 0
    $folders = 0
    $manifest = @()
    $index = 0
    $roots = @(
        @{ Provider = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; Native = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" },
        @{ Provider = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"; Native = "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" }
    )
    foreach ($registryRoot in $roots) {
        if (-not (Test-Path $registryRoot.Provider)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $registryRoot.Provider -ErrorAction SilentlyContinue) {
            $data = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $data) { continue }
            $name = [string](Get-PropertyValue $data "DisplayName")
            $publisher = [string](Get-PropertyValue $data "Publisher")
            $uninstall = [string](Get-PropertyValue $data "QuietUninstallString")
            if ([string]::IsNullOrWhiteSpace($uninstall)) { $uninstall = [string](Get-PropertyValue $data "UninstallString") }
            if ([string]::IsNullOrWhiteSpace($name) -or [int](Get-PropertyValue $data "SystemComponent") -eq 1 -or [int](Get-PropertyValue $data "WindowsInstaller") -eq 1 -or $publisher -match '(?i)^Microsoft(?: Corporation)?$' -or $name -match '(?i)Update|Hotfix|Security Update|Runtime|Redistributable') { continue }
            $uninstaller = Get-ExePath $uninstall
            if ($null -eq $uninstaller -or [IO.Path]::GetFileName($uninstaller) -match '(?i)^(msiexec|rundll32|cmd|powershell|pwsh|wscript|cscript)\.exe$' -or (Test-Path -LiteralPath $uninstaller)) { continue }
            $location = [Environment]::ExpandEnvironmentVariables([string](Get-PropertyValue $data "InstallLocation")).Trim('"')
            $icon = [string](Get-PropertyValue $data "DisplayIcon")
            if ($icon.Contains(',')) { $icon = $icon.Split(',')[0] }
            $icon = [Environment]::ExpandEnvironmentVariables($icon.Trim('"'))
            if (-not [string]::IsNullOrWhiteSpace($icon) -and (Test-Path -LiteralPath $icon)) { continue }
            $locationMissing = [string]::IsNullOrWhiteSpace($location) -or -not (Test-Path -LiteralPath $location)
            $safeFolder = -not $locationMissing -and (Test-ResidueFolder $location)
            if (-not ($locationMissing -or $safeFolder)) { continue }
            $index++
            $regFile = Join-Path $Backup ("uninstall-registry\{0:D4}-{1}.reg" -f $index, (Get-SafeName $name))
            $nativeKey = "{0}\{1}" -f $registryRoot.Native, $key.PSChildName
            if (-not (Export-Key $nativeKey $regFile)) { continue }
            if ($safeFolder) {
                $manifest += [pscustomobject]@{ DisplayName = $name; Path = $location }
                Remove-Item -LiteralPath $location -Recurse -Force -ErrorAction Stop
                $folders++
                Write-Log ("Removed orphaned program folder: {0}" -f $location)
            }
            Remove-Item -LiteralPath $key.PSPath -Recurse -Force -ErrorAction Stop
            $entries++
            Write-Log ("Removed stale uninstall entry: {0}" -f $name)
        }
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Backup "removed-program-folders.json") -Encoding UTF8
    return [pscustomobject]@{ Entries = $entries; Folders = $folders }
}

function Remove-OrphanedTasks {
    $count = 0
    $directory = Join-Path $Backup "scheduled-tasks"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    foreach ($task in Get-ScheduledTask -ErrorAction SilentlyContinue) {
        if ($task.TaskPath -like "\Microsoft\*" -or $task.TaskName -like "HealthRestorer-*") { continue }
        $actions = @($task.Actions | Where-Object { $_.CimClass.CimClassName -eq "MSFT_TaskExecAction" })
        if ($actions.Count -eq 0) { continue }
        $missing = $true
        foreach ($action in $actions) {
            $path = Get-ExePath ([string]$action.Execute)
            if ($null -eq $path -or (Test-Path -LiteralPath $path)) { $missing = $false; break }
        }
        if (-not $missing) { continue }
        Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Set-Content -LiteralPath (Join-Path $directory ((Get-SafeName ($task.TaskPath + $task.TaskName)) + ".xml")) -Encoding UTF8
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false
        $count++
        Write-Log ("Removed orphaned scheduled task: {0}{1}" -f $task.TaskPath, $task.TaskName)
    }
    return $count
}

function Remove-OrphanedServices {
    $count = 0
    $directory = Join-Path $Backup "services"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    foreach ($service in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) {
        $path = Get-ExePath ([string]$service.PathName)
        if ($null -eq $path -or (Test-Path -LiteralPath $path)) { continue }
        $thirdParty = $path -match '(?i)^.:\\(?:Program Files(?: \(x86\))?|ProgramData|Users)\\'
        if (-not $thirdParty) { continue }
        $regFile = Join-Path $directory ((Get-SafeName ([string]$service.Name)) + ".reg")
        if (-not (Export-Key ("HKLM\SYSTEM\CurrentControlSet\Services\{0}" -f $service.Name) $regFile)) { continue }
        $process = Start-Process "sc.exe" -ArgumentList @("delete", [string]$service.Name) -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 1072) { $count++; Write-Log ("Removed orphaned service: {0}" -f $service.Name) }
    }
    return $count
}

function Remove-BrokenShortcuts {
    $count = 0
    $directory = Join-Path $Backup "broken-shortcuts"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $folders = @((Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"), (Join-Path $env:PUBLIC "Desktop"))
    $folders += Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath } | ForEach-Object { (Join-Path $_.LocalPath "Desktop"); (Join-Path $_.LocalPath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs") }
    $index = 0
    foreach ($folder in $folders | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $folder -Filter "*.lnk" -File -Recurse -Depth 6 -Force -ErrorAction SilentlyContinue) {
            try {
                $link = $shell.CreateShortcut($file.FullName)
                $target = [Environment]::ExpandEnvironmentVariables([string]$link.TargetPath)
                if ([string]::IsNullOrWhiteSpace($target) -or -not [IO.Path]::IsPathRooted($target) -or [IO.Path]::GetExtension($target) -notmatch '(?i)^\.(exe|com|bat|cmd|ps1)$' -or (Test-Path -LiteralPath $target)) { continue }
                $index++
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $directory ("{0:D4}-{1}" -f $index, $file.Name)) -Force
                Remove-Item -LiteralPath $file.FullName -Force
                $count++
                Write-Log ("Removed broken shortcut: {0}" -f $file.FullName)
            } catch { Write-Log ("Could not inspect shortcut {0}: {1}" -f $file.FullName, $_.Exception.Message) }
        }
    }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    return $count
}

function Remove-EmptyProgramFolders {
    $count = 0
    $excluded = @("WindowsApps", "WpSystem", "ModifiableWindowsApps", "Common Files", "Microsoft", "Microsoft Shared", "Packages")
    $roots = @([Environment]::GetFolderPath("ProgramFiles"), [Environment]::GetFolderPath("ProgramFilesX86"), $env:ProgramData)
    $roots += Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath } | ForEach-Object { (Join-Path $_.LocalPath "AppData\Local\Programs"); (Join-Path $_.LocalPath "AppData\Roaming") }
    foreach ($base in $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique) {
        $directories = Get-ChildItem -LiteralPath $base -Directory -Recurse -Depth 5 -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not $_.FullName.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object { $_.FullName.Length } -Descending
        foreach ($directory in $directories) {
            if ($excluded -contains $directory.Name) { continue }
            if ($null -ne (Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { continue }
            try { Remove-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop; $count++; Write-Log ("Removed empty program folder: {0}" -f $directory.FullName) } catch { }
        }
    }
    return $count
}

try {
    New-Item -ItemType Directory -Path $Backup -Force | Out-Null
    Write-Log ("Program residue cleanup started. Metadata backup: {0}" -f $Backup)
    $uninstall = Remove-UninstallResidue
    $summary = [ordered]@{
        StaleUninstallEntries = $uninstall.Entries
        OrphanedProgramFolders = $uninstall.Folders
        OrphanedScheduledTasks = Remove-OrphanedTasks
        OrphanedServices = Remove-OrphanedServices
        BrokenShortcuts = Remove-BrokenShortcuts
        EmptyDirectories = Remove-EmptyProgramFolders
        BackupPath = $Backup
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Backup "summary.json") -Encoding UTF8
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
    Write-Log ("Program residue cleanup completed. Entries: {0}; folders: {1}; tasks: {2}; services: {3}; shortcuts: {4}; empty folders: {5}." -f $summary.StaleUninstallEntries, $summary.OrphanedProgramFolders, $summary.OrphanedScheduledTasks, $summary.OrphanedServices, $summary.BrokenShortcuts, $summary.EmptyDirectories)
} catch {
    Write-Log ("Program residue cleanup failed: {0}" -f $_.Exception.Message)
    throw
}
