[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Join-Path $env:ProgramData "HealthRestorer"
$LogPath = Join-Path $Root "health-restorer.log"
$ProgressPath = Join-Path $env:PUBLIC "Desktop\HealthRestorer-progress.txt"
$TaskPath = "\Microsoft\HealthRestorer\"
$SecureTaskName = "HealthRestorer-SecureDeletedData"
$ControllerTaskName = "HealthRestorer-ResumeController"
$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$MainScript = Join-Path $PSScriptRoot "HealthRestorer.ps1"
$SecureScript = Join-Path $PSScriptRoot "SecureDeletedData.ps1"
$ResidueScript = Join-Path $PSScriptRoot "ProgramResidueCleanup.ps1"
$AutorunScript = Join-Path $PSScriptRoot "AutorunAudit.ps1"
$ControllerScript = Join-Path $PSScriptRoot "ResumeController.ps1"
$InstalledSecureScript = Join-Path $Root "SecureDeletedData.ps1"
$InstalledResidueScript = Join-Path $Root "ProgramResidueCleanup.ps1"
$InstalledAutorunScript = Join-Path $Root "AutorunAudit.ps1"
$InstalledControllerScript = Join-Path $Root "ResumeController.ps1"
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

function Write-Progress {
    param(
        [string]$Stage,
        [string]$Details
    )

    $desktop = Split-Path $ProgressPath -Parent
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    @(
        "Health Restorer"
        "Updated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "Stage: $Stage"
        "Details: $Details"
        "Log: $LogPath"
    ) | Set-Content -LiteralPath $ProgressPath -Encoding UTF8
    Write-Log ("PROGRESS [{0}] {1}" -f $Stage, $Details)
}

function Ensure-TaskFolder {
    $service = New-Object -ComObject "Schedule.Service"
    $service.Connect()
    $microsoft = $service.GetFolder("\Microsoft")

    try {
        $microsoft.GetFolder("HealthRestorer") | Out-Null
    }
    catch {
        $microsoft.CreateFolder("HealthRestorer", $null) | Out-Null
    }
}

function Register-SystemTask {
    param(
        [string]$TaskName,
        [string]$ScriptPath,
        [string[]]$ScriptArguments,
        [object[]]$Triggers,
        [int]$RestartCount = 12
    )

    Unregister-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Confirm:$false `
        -ErrorAction SilentlyContinue

    $arguments = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $ScriptPath)
    )
    $arguments += $ScriptArguments

    $action = New-ScheduledTaskAction `
        -Execute $PowerShell `
        -Argument ($arguments -join " ")
    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -RestartCount $RestartCount `
        -RestartInterval (New-TimeSpan -Minutes 5) `
        -ExecutionTimeLimit (New-TimeSpan -Days 31)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Action $action `
        -Trigger $Triggers `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    Get-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -ErrorAction Stop | Out-Null
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
    $AutorunScript,
    $ControllerScript
)) {
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Required script was not found: $script"
    }
}

New-Item -ItemType Directory -Path $Root -Force | Out-Null
Ensure-TaskFolder
Copy-Item -LiteralPath $SecureScript -Destination $InstalledSecureScript -Force
Copy-Item -LiteralPath $ResidueScript -Destination $InstalledResidueScript -Force
Copy-Item -LiteralPath $AutorunScript -Destination $InstalledAutorunScript -Force
Copy-Item -LiteralPath $ControllerScript -Destination $InstalledControllerScript -Force

Write-Progress `
    -Stage "Preparing" `
    -Details "Preparing protected continuation tasks and auditing startup entries."

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

$controllerTriggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn)
)
Register-SystemTask `
    -TaskName $ControllerTaskName `
    -ScriptPath $InstalledControllerScript `
    -ScriptArguments @() `
    -Triggers $controllerTriggers `
    -RestartCount 12
Write-Log "Protected resume controller task registered and verified."

$secureTriggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn)
)
Register-SystemTask `
    -TaskName $SecureTaskName `
    -ScriptPath $InstalledSecureScript `
    -ScriptArguments @("-Mode", "WaitAndClean") `
    -Triggers $secureTriggers `
    -RestartCount 12
Write-Log "Program residue and deleted-data cleanup task registered and verified."

Write-Progress `
    -Stage "OfflineScan" `
    -Details "Microsoft Defender Offline is starting. After restart, the controller will continue with the mandatory full scan and maintenance."

try {
    & $PowerShell `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $MainScript `
        -Mode Start
}
catch {
    Unregister-ScheduledTask `
        -TaskName $SecureTaskName `
        -TaskPath $TaskPath `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    Unregister-ScheduledTask `
        -TaskName $ControllerTaskName `
        -TaskPath $TaskPath `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    $message = $_.Exception.Message
    Write-Log ("Main workflow failed to start: {0}" -f $message)
    Write-Progress -Stage "Failed" -Details $message
    throw
}
