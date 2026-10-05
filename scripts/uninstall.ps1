$ErrorActionPreference = "Stop"

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run uninstall.ps1 from an elevated PowerShell (Run as administrator)."
}

$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$installDir = Join-Path $programFiles "rgbctrl"
$installedExe = Join-Path $installDir "rgbctrl.exe"
$installedGui = Join-Path $installDir "rgbctrl-gui.exe"
$shortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)) "rgbctrl Settings.lnk"
$taskName = "rgbctrl"

if (Test-Path -LiteralPath $shortcut) {
    Remove-Item -LiteralPath $shortcut -Force
    Write-Host "Removed the Start menu shortcut 'rgbctrl Settings'."
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    $null = Disable-ScheduledTask -TaskName $taskName
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

function Get-InstalledProcesses {
    Get-CimInstance Win32_Process -Filter "Name = 'rgbctrl.exe'" | Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $installedExe) }
}

foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'rgbctrl-gui.exe'" | Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $installedGui) })) {
    Write-Host "Closing rgbctrl Settings (process $($process.ProcessId)); unsaved changes in it are lost"
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

$deadline = (Get-Date).AddSeconds(15)
while ((Get-InstalledProcesses) -and ((Get-Date) -lt $deadline)) {
    Start-Sleep -Milliseconds 500
}
foreach ($process in @(Get-InstalledProcesses)) {
    Write-Host "Stopping rgbctrl process $($process.ProcessId)"
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

if ($task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed the scheduled task '$taskName'."
}

if (Test-Path -LiteralPath $installDir) {
    $retired = Join-Path $programFiles ("rgbctrl.old-" + (Get-Date -Format "yyyyMMddHHmmss"))
    try {
        [IO.Directory]::Move($installDir, $retired)
        & cmd.exe /c rmdir /s /q "`"$retired`"" | Out-Null
        if (Test-Path -LiteralPath $retired) {
            Write-Warning "Could not remove $retired now; the next install.ps1 run removes it."
        }
        else {
            Write-Host "Removed $installDir"
        }
    }
    catch {
        Write-Warning "Could not retire $installDir ($($_.Exception.Message)); remove it manually."
    }
}

if ([Diagnostics.EventLog]::SourceExists("rgbctrl")) {
    [Diagnostics.EventLog]::DeleteEventSource("rgbctrl")
}

Write-Host "Kept $programData\rgbctrl (base config) and your user config in %LOCALAPPDATA%\rgbctrl."
Write-Host "Stopping the task terminates rgbctrl without a final save to device memory and without blanking the SK700V display."
