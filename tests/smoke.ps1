param(
    [string]$BuildOutput = "zig-out"
)

$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $repository "$BuildOutput\bin"
$testPlugins = Join-Path $repository "$BuildOutput\test-plugins"
$fixtures = Join-Path $PSScriptRoot "fixtures"
foreach ($required in @("$bin\rgbctrl.exe", "$bin\examples\virtual_led.dll", "$bin\plugins\windows_metrics.dll", "$testPlugins\virtual_null_entry.dll")) {
    if (-not (Test-Path $required)) { throw "missing $required; run 'zig build --release' first" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rgbctrl-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path "$work\bin\plugins" | Out-Null
Copy-Item "$bin\rgbctrl.exe" "$work\bin\"
Copy-Item "$bin\examples\virtual_led.dll" "$work\bin\plugins\"
Copy-Item "$bin\plugins\windows_metrics.dll" "$work\bin\plugins\"
Copy-Item "$testPlugins\*.dll" "$work\bin\plugins\"
$exe = "$work\bin\rgbctrl.exe"
$log = "$work\bin\rgbctrl.log"
$failures = [System.Collections.Generic.List[string]]::new()
# GitHub-hosted Windows runners run elevated, and an elevated rgbctrl refuses to start from this
# user-writable temp folder (exit 4). The flag lets it continue; unelevated it has no effect.
$developmentFlag = "--allow-insecure-install"
$flaggedCommands = @("run", "apply", "list")
$failureContext = $null

function Set-FailureContext([string]$Command, $Result) {
    $script:failureContext = [pscustomobject]@{ Command = $Command; Result = $Result; Reported = $false }
}

function Write-FailureContext {
    $context = $script:failureContext
    if (-not $context -or $context.Reported) { return }
    $context.Reported = $true
    Write-Host "  last command: rgbctrl $($context.Command)"
    if ($context.Result) {
        Write-Host "  exit code: $($context.Result.Code)"
        foreach ($line in ("$($context.Result.Output)".TrimEnd() -split "\r?\n" | Select-Object -First 20)) { Write-Host "  output| $line" }
    }
    $logText = "$(Get-LogText)".TrimEnd()
    if (-not $logText) { Write-Host "  log| (no log file)"; return }
    foreach ($line in ($logText -split "\r?\n" | Select-Object -Last 20)) { Write-Host "  log| $line" }
}

function Test-Condition([string]$Name, [bool]$Condition) {
    if ($Condition) { Write-Host "PASS $Name"; return }
    Write-Host "FAIL $Name"
    $failures.Add($Name)
    Write-FailureContext
}

function Invoke-Rgbctrl([string[]]$Arguments) {
    if ($Arguments.Count -gt 0 -and $flaggedCommands -contains $Arguments[0]) { $Arguments = $Arguments + $developmentFlag }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-String
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $result = [pscustomobject]@{ Code = $code; Output = $output }
    Set-FailureContext ($Arguments -join " ") $result
    return $result
}

function Get-LogText {
    if (Test-Path $log) { return Get-Content $log -Raw }
    return ""
}

function Clear-Log {
    Remove-Item $log -ErrorAction SilentlyContinue
}

function Wait-LogPattern([string]$Pattern, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-LogText) -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Start-Resident([string]$Config) {
    Set-FailureContext "run --config $Config $developmentFlag" $null
    return Start-Process -FilePath $exe -ArgumentList @("run", "--config", "`"$Config`"", $developmentFlag) -PassThru -WindowStyle Hidden
}

function Stop-Resident($Process, [int]$TimeoutMs) {
    $result = Invoke-Rgbctrl @("stop")
    $exited = $Process.WaitForExit($TimeoutMs)
    return ($result.Code -eq 0) -and $exited
}

function Fixture([string]$Name) {
    return Join-Path $fixtures $Name
}

$inventoryPath = "$work\bin\rgbctrl.inventory.json"

function Get-Stamp([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    return "$($item.LastWriteTimeUtc.ToFileTimeUtc()):$($item.Length)"
}

function Wait-Inventory([scriptblock]$Accept, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $inventoryPath) {
            $data = $null
            try { $data = Get-Content $inventoryPath -Raw | ConvertFrom-Json } catch { $data = $null }
            if ($data -and (& $Accept $data)) { return $data }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

try {
    $version = Invoke-Rgbctrl @("version")
    Test-Condition "version prints the version and exits 0" (($version.Code -eq 0) -and ($version.Output -match "rgbctrl \d+\.\d+\.\d+"))
    $usage = Invoke-Rgbctrl @("frobnicate")
    Test-Condition "an unknown command is a usage error (exit 1)" (($usage.Code -eq 1) -and ($usage.Output -match "Usage: rgbctrl"))

    Clear-Log
    $list = Invoke-Rgbctrl @("list", "--config", (Fixture "virtual.json"))
    Test-Condition "list exits 0" ($list.Code -eq 0)
    Test-Condition "list shows the virtual device and zone" (($list.Output -match "virtual: Virtual LED strip") -and ($list.Output -match "strip: 16/64 LEDs"))
    Test-Condition "list rejects a NULL entry" ($list.Output -match "virtual_null_entry.dll: not loaded \(rgbctrl_plugin_entry returned NULL")
    Test-Condition "list rejects abi_version 0 and 2" (($list.Output -match "virtual_abi0.dll: not loaded \(plugin reports an unsupported abi_version") -and ($list.Output -match "virtual_abi2.dll: not loaded \(plugin reports an unsupported abi_version"))
    Test-Condition "list rejects a short plugin table" ($list.Output -match "virtual_short.dll: not loaded \(plugin table struct_size is smaller than ABI v1")
    Test-Condition "list shows Windows sensors" (($list.Output -match "cpu.load: \d") -and ($list.Output -match "mem.load: \d"))
    Test-Condition "list prints both searched config paths" (($list.Output -match "base  .*rgbctrl\.json: ") -and ($list.Output -match "user  .*virtual\.json: used"))
    Test-Condition "list never touches lighting" (-not ((Get-LogText) -match "virtual\.strip: \w+ via |hardware effect \d|frame with first LED"))

    Clear-Log
    $apply = Invoke-Rgbctrl @("apply", "--config", (Fixture "virtual.json"))
    $applyLog = Get-LogText
    Test-Condition "apply exits 0" ($apply.Code -eq 0)
    Test-Condition "apply resizes the zone and sends one host frame" (($applyLog -match "virtual.strip: resized to 24 LEDs") -and ($applyLog -match "virtual.strip: rainbow via host frames") -and ($applyLog -match "frame with first LED red"))
    Test-Condition "apply warns about host-animated effects" ($applyLog -match "apply shows a single frame")
    Test-Condition "apply closes with KEEP" ($applyLog -match "closed \(keep\)")

    Clear-Log
    $broken = Invoke-Rgbctrl @("apply", "--config", (Fixture "broken.json"))
    Test-Condition "apply with a broken config exits 1 without touching lighting" (($broken.Code -eq 1) -and ($broken.Output -match "no lighting was changed") -and (-not ((Get-LogText) -match "virtual device ready")))

    Clear-Log
    $example = Invoke-Rgbctrl @("list", "--config", (Join-Path $repository "rgbctrl.example.json"))
    Test-Condition "the example config parses" (($example.Code -eq 0) -and ((Get-LogText) -match "user config .*rgbctrl\.example\.json: used"))

    Clear-Log
    $typos = Invoke-Rgbctrl @("apply", "--config", (Fixture "typos.json"))
    $typoLog = Get-LogText
    Test-Condition "unknown keys get did-you-mean hints" (($typoLog -match 'unknown key "lightning"; did you mean "lighting"') -and ($typoLog -match 'lighting.virtul matches no connected device; did you mean "virtual"') -and ($typoLog -match 'lighting.virtual.strp matches no zone of virtual; did you mean "strip"') -and ($typoLog -match 'unknown key "lighting.virtual.strip.efect"; did you mean "effect"') -and ($typoLog -match 'plugins.virtual_ld matches no loaded plugin; did you mean "virtual_led"'))

    Clear-Log
    $invalid = Invoke-Rgbctrl @("list", "--config", (Fixture "invalid_effect.json"))
    Test-Condition "list reports an invalid zone setting and exits 1 without touching lighting" (($invalid.Code -eq 1) -and ($invalid.Output -match "error: .*lighting\.virtual\.strip\.effect") -and (-not ((Get-LogText) -match "virtual\.strip: \w+ via ")))

    Clear-Log
    $failOpen = Invoke-Rgbctrl @("list", "--config", (Fixture "fail_open.json"))
    Test-Condition "a failing open is reported and the list still completes" (($failOpen.Code -eq 0) -and ((Get-LogText) -match "open failed \(E_FAIL\)"))

    Clear-Log
    $devices = Invoke-Rgbctrl @("list", "--config", (Fixture "devices.json"))
    Test-Condition "an invalid device is rejected and the valid ones stay" (($devices.Output -match "virtual2: Second virtual LED strip") -and ((Get-LogText) -match "device 1 rejected: device id"))

    Clear-Log
    $hardwareOnly = Invoke-Rgbctrl @("apply", "--config", (Fixture "hardware_only.json"))
    Test-Condition "an effect no engine can show leaves the zone unchanged" ((Get-LogText) -match "neither the hardware nor host frames can show rainbow")

    $checkInstall = Invoke-Rgbctrl @("check-install", "--dir", "$work\bin")
    Test-Condition "check-install fails (exit 4) for a user-writable folder" (($checkInstall.Code -eq 4) -and ($checkInstall.Output -match "FAIL"))
    Test-Condition "list and apply write no inventory" (-not (Test-Path $inventoryPath))

    Clear-Log
    $userConfig = "$work\user.json"
    Copy-Item (Fixture "virtual.json") $userConfig
    $resident = Start-Resident $userConfig
    Test-Condition "run starts and animates" (Wait-LogPattern "virtual.strip: rainbow via host frames" 10)
    Test-Condition "run keeps sending frames" (Wait-LogPattern "(?s)frame with first LED red.*frame with first LED red.*frame with first LED red" 5)
    $inventory = Wait-Inventory { param($data) $data.devices | Where-Object { $_.key -eq "virtual" } } 10
    Test-Condition "run publishes the inventory next to its log" ($null -ne $inventory)
    if ($inventory) {
        $virtual = $inventory.devices | Where-Object { $_.key -eq "virtual" }
        $plugin = $inventory.plugins | Where-Object { $_.name -eq "virtual_led" }
        $user = $inventory.config.user
        Test-Condition "the inventory lists the virtual zone, the active plugin and the user config" (($inventory.format -eq 1) -and ($virtual.zones[0].name -eq "strip") -and ($virtual.zones[0].max_leds -eq 64) -and ($virtual.zones[0].resizable -eq $true) -and ($plugin.state -eq "active") -and ($user.path -eq $userConfig) -and ($user.applied_stamp -eq (Get-Stamp $userConfig)) -and ($user.attempted_stamp -eq $user.applied_stamp) -and ($user.failed -eq $false))
    }
    Test-Condition "the inventory reports the LED count after a resize" ($null -ne (Wait-Inventory { param($data) ($data.devices | Where-Object { $_.key -eq "virtual" }).zones[0].leds -eq 24 } 10))
    $second = Invoke-Rgbctrl @("list", "--config", $userConfig)
    Test-Condition "a second instance exits 2 and names the stop commands" (($second.Code -eq 2) -and ($second.Output -match "Stop-ScheduledTask"))
    Start-Sleep -Milliseconds 1200
    Copy-Item -Force (Fixture "virtual_static.json") $userConfig
    Test-Condition "run reloads a changed config" (Wait-LogPattern "virtual.strip: static via hardware" 10)
    $expectedStamp = Get-Stamp $userConfig
    Test-Condition "the inventory reports the stamp of the reloaded config" ($null -ne (Wait-Inventory { param($data) $data.config.user.applied_stamp -eq $expectedStamp } 10))
    Start-Sleep -Milliseconds 1200
    Copy-Item -Force (Fixture "broken.json") $userConfig
    $brokenStamp = Get-Stamp $userConfig
    Test-Condition "a refused reload keeps the applied stamp and reports the file it could not use" ($null -ne (Wait-Inventory { param($data) $data.config.kept_previous -and $data.config.user.failed -and ($data.config.user.attempted_stamp -eq $brokenStamp) -and ($data.config.user.applied_stamp -eq $expectedStamp) } 10))
    Test-Condition "stop ends the resident instance" (Stop-Resident $resident 8000)
    Test-Condition "run exits with code 0 and closes with EXIT" (($resident.ExitCode -eq 0) -and ((Get-LogText) -match "closed \(exit\)"))

    Clear-Log
    $resident = Start-Resident (Fixture "stall.json")
    Test-Condition "a stalled plugin call is reported" (Wait-LogPattern "flush has not returned after \d+ ms" 12)
    Test-Condition "the stalled call is reported again when it returns" (Wait-LogPattern "flush returned after \d+ ms" 8)
    Test-Condition "Windows sensors keep updating while another plugin stalls" ((Get-LogText) -notmatch "windows_metrics.*has not returned")
    Test-Condition "stop works while a plugin is slow" (Stop-Resident $resident 10000)

    Clear-Log
    $resident = Start-Resident (Fixture "lose.json")
    Test-Condition "a lost device schedules a recovery" (Wait-LogPattern "device lost; retrying in 5 s" 10)
    Test-Condition "the device recovers" (Wait-LogPattern "\[virtual_led\] recovered" 12)
    Test-Condition "stop after recovery" (Stop-Resident $resident 8000)

    Clear-Log
    $resident = Start-Resident (Fixture "abandon.json")
    $null = Wait-LogPattern "virtual.strip: rainbow via host frames" 10
    Start-Sleep -Milliseconds 500
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stopped = Stop-Resident $resident 8000
    $stopwatch.Stop()
    Test-Condition "an unresponsive plugin is abandoned within about 3 s and the exit code stays 0" ($stopped -and ($resident.ExitCode -eq 0) -and ($stopwatch.ElapsedMilliseconds -lt 6000) -and ((Get-LogText) -match "abandoning it"))
}
finally {
    Get-Process rgbctrl -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | ForEach-Object { Stop-Process -Id $_.Id -Force }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) smoke checks failed"
    exit 1
}
Write-Host "all smoke checks passed"
exit 0
