param(
    [switch]$StartNow,
    [switch]$AllowSharedSource,
    [string]$BuildOutput = "zig-out"
)

$ErrorActionPreference = "Stop"

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run install.ps1 from an elevated PowerShell (Run as administrator)."
}

$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$installDir = Join-Path $programFiles "rgbctrl"
$baseDir = Join-Path $programData "rgbctrl"
$userDir = Join-Path $localAppData "rgbctrl"
$userFile = Join-Path $userDir "rgbctrl.json"
$repository = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repository "$BuildOutput\bin"
$taskName = "rgbctrl"

function Remove-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    & cmd.exe /c rmdir /s /q "`"$Path`"" | Out-Null
    if (Test-Path -LiteralPath $Path) { throw "Could not remove $Path; remove it manually and run install.ps1 again." }
}

function Invoke-CheckInstall([string]$Executable) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Executable check-install 2>&1 | ForEach-Object { "$_" } | Out-String
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $verdict = "unknown"
    if ($output -match "Base config: absent") { $verdict = "absent" }
    elseif ($output -match "Base config: trusted") { $verdict = "trusted" }
    elseif ($output -match "Base config: untrusted") { $verdict = "untrusted" }
    $passed = (($code -eq 0) -or ($code -eq 5)) -and ($verdict -ne "unknown") -and ($output -match "Install rules: passed")
    return [pscustomobject]@{ Code = $code; Output = $output; Base = $verdict; Passed = $passed }
}

$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$trustedSids = @("S-1-5-18", "S-1-5-32-544", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464", "S-1-3-4", "S-1-3-0", $currentSid)
$fileWriteRights = 0x0002 -bor 0x0004 -bor 0x0010 -bor 0x0100 -bor 0x10000 -bor 0x40 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
$ancestorWriteRights = 0x10000 -bor 0x40 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000

function Get-UntrustedWriters([string]$Path, [int]$Rights) {
    $acl = Get-Acl -LiteralPath $Path
    $problems = @()
    $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($trustedSids -notcontains $ownerSid) { $problems += "owned by $ownerSid" }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        $sid = $rule.IdentityReference.Value
        if ($trustedSids -contains $sid) { continue }
        if (([int]$rule.FileSystemRights) -band $Rights) { $problems += "$sid may modify it ($($rule.FileSystemRights))" }
    }
    return $problems
}

function Set-AdministratorsOwner([string]$Path) {
    & icacls.exe $Path /setowner "*S-1-5-32-544" /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /setowner failed for $Path" }
}

foreach ($pattern in @("rgbctrl.staging-*", "rgbctrl.base-staging-*", "rgbctrl.old-*")) {
    Get-ChildItem -LiteralPath $programFiles -Directory -Filter $pattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Removing leftover $($_.FullName)"
        Remove-Directory $_.FullName
    }
}
if (Test-Path -LiteralPath $installDir) {
    throw "$installDir already exists. Run scripts\uninstall.ps1 first; install.ps1 only performs fresh installs."
}

if (-not (Test-Path -LiteralPath (Join-Path $source "rgbctrl.exe"))) {
    throw "$source\rgbctrl.exe not found. Build first with: zig build --release"
}
$sourceItems = @(Get-Item -LiteralPath $source -Force) + @(Get-ChildItem -LiteralPath $source -Recurse -Force)
foreach ($item in $sourceItems) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing to install from a reparse point: $($item.FullName)" }
}
$payload = @(Get-Item -LiteralPath (Join-Path $source "rgbctrl.exe"))
$payload += @(Get-ChildItem -LiteralPath $source -File -Filter "rgbctrl.example.json" -Force)
$payload += @(Get-ChildItem -LiteralPath $source -File -Filter "rgbctrl-gui.exe" -Force)
$sourceFolders = @(Get-Item -LiteralPath $source -Force)
foreach ($folder in @("plugins", "pawnio")) {
    $path = Join-Path $source $folder
    if (Test-Path -LiteralPath $path) {
        $sourceFolders += @(Get-Item -LiteralPath $path -Force)
        $payload += @(Get-ChildItem -LiteralPath $path -File -Force)
    }
}

$sourceProblems = @()
foreach ($item in @($payload) + @($sourceFolders)) {
    foreach ($problem in (Get-UntrustedWriters $item.FullName $fileWriteRights)) { $sourceProblems += "$($item.FullName): $problem" }
}
$ancestor = Split-Path -Parent $source
while ($ancestor) {
    foreach ($problem in (Get-UntrustedWriters $ancestor $ancestorWriteRights)) { $sourceProblems += "${ancestor}: $problem" }
    $parent = Split-Path -Parent $ancestor
    if ($parent -eq $ancestor) { break }
    $ancestor = $parent
}
if ($sourceProblems.Count -gt 0) {
    $details = $sourceProblems -join "`n  "
    if (-not $AllowSharedSource) {
        throw "Other accounts can modify the build output, so its files cannot be trusted for a SYSTEM service:`n  $details`nBuild in a folder only you and administrators can write to (for example under your user profile) and run install.ps1 again. If you accept the risk, run: scripts\install.ps1 -AllowSharedSource"
    }
    Write-Warning "Installing from a build output that other accounts can modify (-AllowSharedSource):`n  $details"
}

$staging = Join-Path $programFiles ("rgbctrl.staging-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $staging
try {
    foreach ($file in $payload) {
        $relative = $file.FullName.Substring($source.Length).TrimStart("\")
        $target = Join-Path $staging $relative
        $targetFolder = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetFolder)) { $null = New-Item -ItemType Directory -Path $targetFolder }
        $sourceStream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $targetStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $sourceStream.CopyTo($targetStream) } finally { $targetStream.Dispose() }
        }
        finally {
            $sourceStream.Dispose()
        }
    }
    Set-AdministratorsOwner $staging
    & icacls.exe $staging /reset /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed for $staging" }
    $stagedCheck = Invoke-CheckInstall (Join-Path $staging "rgbctrl.exe")
    if (-not $stagedCheck.Passed) { throw "The staged copy did not pass check-install (exit code $($stagedCheck.Code)):`n$($stagedCheck.Output)" }
    [IO.Directory]::Move($staging, $installDir)
}
catch {
    Remove-Directory $staging
    throw
}

$installedExe = Join-Path $installDir "rgbctrl.exe"
$installedCheck = Invoke-CheckInstall $installedExe
if (-not $installedCheck.Passed) {
    Remove-Directory $installDir
    throw "The installed copy did not pass check-install (exit code $($installedCheck.Code)):`n$($installedCheck.Output)"
}

if ($installedCheck.Base -eq "untrusted") {
    Remove-Directory $installDir
    throw "$baseDir exists but is not admin-only. Inspect it and remove it (for example: cmd /c rmdir /s /q `"$baseDir`"), then run install.ps1 again. The install was rolled back.`n$($installedCheck.Output)"
}
if ($installedCheck.Base -eq "absent") {
    $baseStaging = Join-Path $programFiles ("rgbctrl.base-staging-" + [guid]::NewGuid().ToString("N"))
    $createdBase = $false
    try {
        $null = New-Item -ItemType Directory -Path $baseStaging
        Set-AdministratorsOwner $baseStaging
        & icacls.exe $baseStaging /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls could not protect $baseStaging" }
        $template = @(
            "{",
            "  `"plugins`": {",
            "  }",
            "}",
            ""
        ) -join "`r`n"
        $stream = [IO.File]::Open((Join-Path $baseStaging "rgbctrl.json"), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($template)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Dispose()
        }
        Set-AdministratorsOwner $baseStaging
        try {
            [IO.Directory]::Move($baseStaging, $baseDir)
        }
        catch {
            throw "Could not move the new base config folder to $baseDir ($($_.Exception.Message)). It may have been created meanwhile, or %ProgramData% is on a different volume than %ProgramFiles%."
        }
        $createdBase = $true
        $baseCheck = Invoke-CheckInstall $installedExe
        if ($baseCheck.Base -ne "trusted") { throw "The new base config folder is not trusted:`n$($baseCheck.Output)" }
    }
    catch {
        if ($createdBase) { Remove-Directory $baseDir }
        Remove-Directory $baseStaging
        Remove-Directory $installDir
        throw
    }
}

if (-not (Test-Path -LiteralPath $userFile)) {
    if (-not (Test-Path -LiteralPath $userDir)) { $null = New-Item -ItemType Directory -Path $userDir }
    Copy-Item -LiteralPath (Join-Path $source "rgbctrl.example.json") -Destination $userFile
    Write-Host "Created $userFile from the example; edit it to choose colors and effects."
}

$registeredTask = $false
$createdSource = $false
$installedGui = Join-Path $installDir "rgbctrl-gui.exe"
$shortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)) "rgbctrl Settings.lnk"
$createdShortcut = $false
try {
    $action = New-ScheduledTaskAction -Execute $installedExe -Argument "run --config `"$userFile`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings
    $registeredTask = $true
    if (-not [Diagnostics.EventLog]::SourceExists("rgbctrl")) {
        [Diagnostics.EventLog]::CreateEventSource("rgbctrl", "Application")
        $createdSource = $true
    }
    if (Test-Path -LiteralPath $installedGui) {
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
        $link.TargetPath = $installedGui
        $link.WorkingDirectory = $installDir
        $link.Description = "Choose the lighting effects, colors and plugins rgbctrl uses"
        $link.Save()
        $createdShortcut = $true
    }
}
catch {
    if ($createdShortcut) { Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue }
    if ($registeredTask) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
    if ($createdSource) { [Diagnostics.EventLog]::DeleteEventSource("rgbctrl") }
    Remove-Directory $installDir
    throw
}

Write-Host "Installed rgbctrl to $installDir"
Write-Host "Base config: $baseDir\rgbctrl.json (admin-only)"
Write-Host "User config: $userFile"
Write-Host "Scheduled task '$taskName' runs rgbctrl as SYSTEM at startup. Log: $installDir\rgbctrl.log"
if ($createdShortcut) { Write-Host "Settings window: Start menu > rgbctrl Settings ($installedGui)" }
if ($StartNow) {
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Started the task."
}
else {
    Write-Host "Start it now with: Start-ScheduledTask -TaskName $taskName"
}
