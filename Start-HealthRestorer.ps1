[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Join-Path $env:ProgramData "HealthRestorer"
$LogPath = Join-Path $Root "health-restorer.log"
$TaskName = "HealthRestorer-SecureDeletedData"
$TaskPath = "\Microsoft\HealthRestorer\"
$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$MainScript = Join-Path $PSScriptRoot "HealthRestorer.ps1"
$SecureScript = Join-Path $PSScriptRoot "SecureDeletedData.ps1"
$ResidueScript = Join-Path $PSScriptRoot "ProgramResidueCleanup.ps1"
$AutorunScript = Join-Path $PSScriptRoot "AutorunAudit.ps1"
$InstalledSecureScript = Join-Path $Root "SecureDeletedData.ps1"
$InstalledResidueScript = Join-Path $Root "ProgramResidueCleanup.ps1"
$InstalledAutorunScript = Join-Path $Root "AutorunAudit.ps1"
$AutorunReport = Join-Path $Root "autorun-audit.json"

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

if (-not (Test-Administrator)) {
    Start-Process `
        -FilePath $PowerShell `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

foreach ($script in @(
    $MainScript,
    $SecureScript,
    $ResidueScript,
    $AutorunScript
)) {
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Required script was not found: $script"
    }
}

New-Item -ItemType Directory -Path $Root -Force | Out-Null
Copy-Item -LiteralPath $SecureScript -Destination $InstalledSecureScript -Force
Copy-Item -LiteralPath $ResidueScript -Destination $InstalledResidueScript -Force
Copy-Item -LiteralPath $AutorunScript -Destination $InstalledAutorunScript -Force

try {
    $audit = Start-Process `
        -FilePath $PowerShell `
        -ArgumentList @(
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", $InstalledAutorunScript,
            "-ReportPath", $AutorunReport
        ) `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    if ($audit.ExitCode -ne 0) {
        Write-Log ("Comprehensive autorun audit returned exit code {0}." -f $audit.ExitCode)
    }
}
catch {
    Write-Log ("Comprehensive autorun audit failed: {0}" -f $_.Exception.Message)
}

Unregister-ScheduledTask `
    -TaskName $TaskName `
    -TaskPath $TaskPath `
    -Confirm:$false `
    -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $PowerShell -Argument (
    "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"{0}`" -Mode WaitAndClean" -f $InstalledSecureScript
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
    -TaskPath $TaskPath `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Write-Log "Program residue and deleted-data cleanup task registered."

try {
    & $PowerShell `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $MainScript `
        -Mode Start
}
catch {
    Unregister-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    Write-Log ("Main workflow failed to start: {0}" -f $_.Exception.Message)
    throw
}
