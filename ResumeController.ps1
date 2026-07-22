[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Join-Path $env:ProgramData "HealthRestorer"
$MainScript = Join-Path $Root "HealthRestorer.ps1"
$StatePath = Join-Path $Root "state.txt"
$LogPath = Join-Path $Root "health-restorer.log"
$ProgressPath = Join-Path $env:PUBLIC "Desktop\HealthRestorer-progress.txt"
$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$ControllerTaskName = "HealthRestorer-ResumeController"
$ControllerTaskPath = "\Microsoft\HealthRestorer\"
$LegacyTaskName = "HealthRestorer-OneTime"

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

function Stop-LegacyResumeTask {
    Stop-ScheduledTask `
        -TaskName $LegacyTaskName `
        -ErrorAction SilentlyContinue
    Unregister-ScheduledTask `
        -TaskName $LegacyTaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    Write-Log "Legacy resume task stopped and removed."
}

function Remove-ControllerTask {
    Unregister-ScheduledTask `
        -TaskName $ControllerTaskName `
        -TaskPath $ControllerTaskPath `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    Write-Log "Resume controller task removed."
}

function Get-WorkflowState {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return "Missing"
    }

    try {
        return (Get-Content -LiteralPath $StatePath -Raw).Trim()
    }
    catch {
        return "Unreadable"
    }
}

function Wait-ForWindowsServices {
    Write-Progress `
        -Stage "WaitingForWindows" `
        -Details "Waiting for Task Scheduler, WMI and Microsoft Defender."

    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
        $ready = $true

        foreach ($name in @("Schedule", "Winmgmt", "WinDefend")) {
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $service) {
                $ready = $false
                continue
            }

            if ($service.Status -ne "Running") {
                Start-Service -Name $name -ErrorAction SilentlyContinue
                $ready = $false
            }
        }

        if ($ready) {
            try {
                $status = Get-MpComputerStatus -ErrorAction Stop
                if ($status.AntivirusEnabled) {
                    Start-Sleep -Seconds 30
                    return
                }
            }
            catch {
            }
        }

        Start-Sleep -Seconds 15
    }

    throw "Windows or Microsoft Defender did not become ready within 30 minutes."
}

function Get-StageDescription {
    param([string]$State)

    switch ($State) {
        "AfterOffline" {
            return "Running the mandatory full Microsoft Defender scan of all accessible files."
        }
        "AfterDisk" {
            return "Running DISM, SFC, cache cleanup, disk checks and optimization."
        }
        "Maintenance" {
            return "Resuming interrupted Windows maintenance."
        }
        "Completed" {
            return "Main maintenance is complete. Final residue and deleted-data cleanup may still be running."
        }
        default {
            return "Continuing workflow state: $State"
        }
    }
}

if (-not (Test-Administrator)) {
    Start-Process `
        -FilePath $PowerShell `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

try {
    Stop-LegacyResumeTask

    if (-not (Test-Path -LiteralPath $MainScript)) {
        throw "Main workflow script was not found: $MainScript"
    }

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $state = Get-WorkflowState

        if ($state -eq "Completed") {
            Write-Progress `
                -Stage "Completed" `
                -Details (Get-StageDescription -State $state)
            Remove-ControllerTask
            exit 0
        }

        Write-Log ("Resume attempt {0}/12. Current state: {1}." -f $attempt, $state)

        try {
            Wait-ForWindowsServices
            $state = Get-WorkflowState
            Write-Progress `
                -Stage $state `
                -Details (Get-StageDescription -State $state)

            $process = Start-Process `
                -FilePath $PowerShell `
                -ArgumentList @(
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy", "Bypass",
                    "-File", $MainScript,
                    "-Mode", "Resume"
                ) `
                -Wait `
                -PassThru `
                -WindowStyle Hidden

            Write-Log ("Main resume process exited with code {0}." -f $process.ExitCode)

            if ($process.ExitCode -ne 0) {
                throw "Main resume process returned exit code $($process.ExitCode)."
            }

            $state = Get-WorkflowState
            if ($state -eq "Completed") {
                Write-Progress `
                    -Stage "Completed" `
                    -Details (Get-StageDescription -State $state)
                Remove-ControllerTask
                exit 0
            }

            Start-Sleep -Seconds 30
        }
        catch {
            $message = $_.Exception.Message
            Write-Log ("Resume attempt {0} failed: {1}" -f $attempt, $message)
            Write-Progress `
                -Stage "Retrying" `
                -Details ("Attempt {0}/12 failed: {1}. Retrying in five minutes." -f $attempt, $message)

            if ($attempt -lt 12) {
                Start-Sleep -Minutes 5
            }
        }
    }

    throw "All 12 resume attempts failed."
}
catch {
    $message = $_.Exception.Message
    Write-Log ("RESUME CONTROLLER FATAL: {0}" -f $message)
    try {
        Write-Progress -Stage "Failed" -Details $message
    }
    catch {
    }
    throw
}
