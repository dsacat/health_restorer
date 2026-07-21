[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Join-Path $env:ProgramData "HealthRestorer"
$logPath = Join-Path $root "health-restorer.log"
$taskName = "HealthRestorer-SecureDeletedData"
$powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$mainScript = Join-Path $PSScriptRoot "HealthRestorer.ps1"
$secureScript = Join-Path $PSScriptRoot "SecureDeletedData.ps1"
$installedSecureScript = Join-Path $root "SecureDeletedData.ps1"

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

if (-not (Test-Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process -FilePath $powerShellPath -Verb RunAs -ArgumentList $arguments
    exit
}

if (-not (Test-Path $mainScript)) {
    throw "HealthRestorer.ps1 was not found next to the launcher."
}

if (-not (Test-Path $secureScript)) {
    throw "SecureDeletedData.ps1 was not found next to the launcher."
}

New-Item -ItemType Directory -Path $root -Force | Out-Null
Copy-Item -LiteralPath $secureScript -Destination $installedSecureScript -Force

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument (
    "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"{0}`" -Mode WaitAndClean" -f $installedSecureScript
)
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Days 7)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Write-Log "Secure deleted-data cleanup task registered."

try {
    & $powerShellPath `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $mainScript `
        -Mode Start
}
catch {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log ("Main workflow failed to start: {0}" -f $_.Exception.Message)
    throw
}
