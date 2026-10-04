# rgbctrl

rgbctrl is a small native Windows program that controls the RGB lighting and the LED
display on one specific PC without any vendor software. It reads a JSON configuration file,
drives each device through its own plugin DLL, writes a text log for diagnostics, and runs
either once (`apply`) or resident (`run`, for example as a SYSTEM scheduled task).

- `rgbctrl.exe` (the host) knows nothing about any device. It parses the configuration,
  loads the plugins, renders host-side effects and supervises one worker thread per plugin.
- Every device family is a separate DLL in `plugins\` that implements the C ABI in
  `include\rgbctrl_plugin.h`. Anyone can add hardware by writing another DLL, in Zig with the
  SDK in `sdk\` or in C (see `examples\c_plugin\virtual_led.c` and `docs\plugin-abi.md`).
- Written in Zig 0.17.0 against the Win32 API directly; no runtime dependencies besides
  Windows itself (and the PawnIO driver for the features that need it).

Status: all protocol code is unit tested with byte vectors taken from the protocol research,
and the host is tested end to end with a virtual device (`tests\smoke.ps1`). Follow the
first-run checklist below and enable one device at a time.

## Supported hardware

| Part | What rgbctrl controls | Plugin | Notes |
|---|---|---|---|
| Gigabyte X870E AORUS PRO ICE (ITE IT5711, USB 048D:5711) | 3 ARGB headers, 12 V RGB header, I/O cover, chipset | `gigabyte_fusion2` | set `leds` for each ARGB header |
| Gigabyte AORUS RTX 5080 MASTER ICE (and other allowlisted Gigabyte GeForce cards) | fan rings and logos; on the 5080 MASTER ICE also GPU readings on the LCD (opt-in) | `gigabyte_gpu` | see "GPU readings on the RTX 5080 LCD" |
| Corsair Vengeance RGB DDR5 | 10 LEDs per DIMM | `corsair_ddr5` | opt-in; needs PawnIO and elevation |
| Keychron Q6 Max (3434:0860/0861/0862) and Q6 HE (3434:0B60/0B61/0B62) | per-key RGB | `keychron` | USB cable only (cable mode); per-key frames need firmware with the 0xA8 protocol |
| SteelSeries Apex Pro, the full-size 2019 model (KB-00009, 1038:1610) | per-key RGB | `steelseries_apex` | host frames only; shows its own stored lighting until rgbctrl applies the zone |
| Sudokoo SK700V (381C:0003) | CPU temperature, power, load and frequency readout | `sudokoo_sk700v` | the display has no fan speed field |
| AMD Ryzen (Zen and later) | sensors: `cpu.temp`, `cpu.ccd<N>.temp`, `cpu.power` | `amd_cpu` | needs PawnIO and elevation |
| Windows | sensors: `cpu.load`, `cpu.freq`, `mem.load` | `windows_metrics` | |
| NVIDIA GeForce | sensors: `gpu.temp`, `gpu.load`, `gpu.power`, `gpu.fan`, `gpu.freq`, `gpu.mem.freq`, `gpu.mem.load` | `nvidia_gpu` | the first NVIDIA GPU, through the driver's NVML |

`docs\devices.md` has the details for every device: zone names, supported effects, what the
plugin sends during discovery, and known conflicts.

## Build

1. Install Zig 0.17.0 (`winget install zig.zig --version 0.17.0`).
2. `zig build --release` builds everything into `zig-out\`:
   - `bin\rgbctrl.exe`, `bin\plugins\*.dll`, `bin\rgbctrl.example.json`
   - `bin\pawnio\AMDFamily17.bin` and `bin\pawnio\SmbusPIIX4.bin` (downloaded once from the
     pinned PawnIO.Modules 0.2.11 release and verified by hash; `-Dpawnio-modules=false` skips them)
   - `bin\examples\virtual_led.dll` (the example plugin) and `include\rgbctrl_plugin.h`
3. `zig build test` runs the unit tests; `pwsh tests\smoke.ps1` runs the end-to-end tests
   against the virtual plugin (it never loads the hardware plugins).

Stability and readable code come before binary size. CI still fails a release build with a
plugin above 128 KiB or an `rgbctrl.exe` above 512 KiB, but only to catch accidents such as a
Debug build in the release output (today the plugins are 9 to 30 KiB and `rgbctrl.exe` about
160 KiB).

To install rgbctrl as a SYSTEM task later (see "Run at startup"), build in a folder that only
you and administrators can modify, for example under your user profile: folders created
directly under `C:\` usually let every signed-in user change them, and the installer refuses
to copy such a build into the protected program folder.

## First-run checklist

1. Close or uninstall the vendor tools that talk to the same devices: Gigabyte Control Center /
   RGB Fusion, AORUS Engine / GCC GPU lighting, Keychron Launcher (a browser tab with it open
   also holds the keyboard), SteelSeries GG, the Sudokoo / MasterCraft display software,
   Corsair iCUE, OpenRGB, SignalRGB. rgbctrl opens the HID devices exclusively and reports "in
   use by another application" when another program holds them. Windows Dynamic Lighting
   (Settings > Personalization > Dynamic Lighting) should be turned off for these devices.
2. For CPU temperature and power on the SK700V display and for DDR5 lighting, install the
   signed PawnIO driver: `winget install namazso.PawnIO`. These features also need rgbctrl to
   run elevated (the scheduled task does).
3. Run `zig-out\bin\rgbctrl.exe list`. It shows the plugins, the devices and zones found on
   this PC, and the sensors, without changing any lighting. The log `rgbctrl.log` next to
   `rgbctrl.exe` (or in `%LOCALAPPDATA%\rgbctrl\` when that folder is not writable) has the
   details, including every probe the plugins made. Unelevated, `cpu.temp` and `cpu.power`
   show as unavailable. An elevated run refuses to start from a folder that is not admin-only
   (such as `zig-out\bin`, exit code 4); either install first (see "Run at startup") and run
   the installed `rgbctrl.exe`, or add `--allow-insecure-install` for a one-off test.
4. Create your configuration at `%LOCALAPPDATA%\rgbctrl\rgbctrl.json`. Start from
   `rgbctrl.example.json` and keep only the devices you want to change; zones that are not
   mentioned are left untouched, except that the Gigabyte motherboard clears all of its zones
   before rgbctrl first writes to it (see `docs\devices.md`). `docs\configuration.md`
   describes every key.
5. `rgbctrl apply` applies hardware effects and one frame of host effects and exits;
   `rgbctrl run` keeps animating, updates the SK700V display every second and reloads the
   configuration when you save it. Stop it with Ctrl+C or `rgbctrl stop`.
6. Enable devices one at a time. Leave DDR5 for last: it is opt-in and must be enabled in the
   admin-only base file (`"plugins": {"corsair_ddr5": {"enabled": true}}` in
   `%ProgramData%\rgbctrl\rgbctrl.json`).

## Run at startup

`scripts\install.ps1` (from an elevated PowerShell, after `zig build --release`) performs a
fresh install:

- refuses to install when accounts other than you, SYSTEM and Administrators can modify the
  build output or its parent folders (folders created directly under `C:\` usually let every
  signed-in user modify them); build under your user profile, or pass `-AllowSharedSource` if
  you accept that risk,
- copies rgbctrl into `%ProgramFiles%\rgbctrl` with an admin-only ACL and verifies it with
  `rgbctrl check-install`,
- creates the admin-only base config folder `%ProgramData%\rgbctrl` if it does not exist,
- creates `%LOCALAPPDATA%\rgbctrl\rgbctrl.json` from the example if it does not exist,
- registers the scheduled task `rgbctrl` that runs `rgbctrl run --config <your user file>` as
  SYSTEM at startup, and the Event Log source `rgbctrl`. `-StartNow` starts it immediately.

Control the task with `Start-ScheduledTask -TaskName rgbctrl` and
`Stop-ScheduledTask -TaskName rgbctrl`, or `rgbctrl stop` from an elevated prompt (that path
lets rgbctrl shut down cleanly: final save to device memory when enabled, SK700V blanked).
Stopping the task terminates the process without that cleanup. The log of the task is
`%ProgramFiles%\rgbctrl\rgbctrl.log`. `scripts\uninstall.ps1` removes the task, the program
folder and the Event Log source and keeps both configuration files. Upgrades are an uninstall
followed by an install.

## Making hardware effects survive gaming and reboots

`static`, `breathing`, `flash` and `cycle` on the Gigabyte motherboard and GPU run as
*hardware* effects: rgbctrl writes them once into the controller's volatile memory. When an RGB
controller resets it reloads the profile stored inside it, which is usually the vendor's
rainbow. rgbctrl re-applies automatically after system sleep and resume, but two cases it
cannot cover on its own:

- The GPU waking from idle to run a game. The moment the fans spin up, the card's RGB
  controller resets and reloads its stored rainbow, and rgbctrl gets no power-state signal to
  re-assert, so the colors stay reverted until the next config reload or restart.
- A reboot. The controllers power up showing their stored profile until the rgbctrl task starts
  and applies your config; the motherboard waits until Windows has been running 5 minutes (see
  "Known limitations").

Enable `persist` for the Gigabyte plugins so rgbctrl saves the applied effect into the
controller's non-volatile memory; the controller then reloads your colors on a reset instead of
the rainbow. `persist` is a privileged key, so it belongs in the admin-only base config
`%ProgramData%\rgbctrl\rgbctrl.json` (the user config can only tighten it). Merge it with
whatever is already there:

```json
{
  "plugins": {
    "gigabyte_gpu":     { "persist": true },
    "gigabyte_fusion2": { "persist": true }
  }
}
```

A resident `run` saves once a device's effects have been unchanged for 60 s, and no more than
once a minute per device; look for `saved the current settings to device memory` in the log.
The save captures whatever is showing at that instant, so apply your colors and wait for that
line before launching a game. `apply` never writes device memory. `docs\configuration.md`
("Saving to device memory") has the full policy.

## GPU readings on the RTX 5080 LCD

The LCD of the AORUS RTX 5080 MASTER ICE can overlay live GPU readings on its built-in
screens and rotate through them. rgbctrl can switch that overlay on and feed it the values that
`nvidia_gpu` reads from the NVIDIA driver once a second. It never uploads images and never
saves anything into the panel.

The card ships with one of two LCD controllers, and its PCI identity does not tell which:

- the older one at I2C address 0x61, whose protocol open-source projects reverse-engineered
  from Gigabyte Control Center (firmware F1.4 on the card they tested);
- Gigabyte's newer one ("LcdEx" in its software) at 0x76, found on the card rgbctrl was tested
  with (firmware 1.5). rgbctrl sends it the commands of Gigabyte Control Center 26.09 and its
  `AorusLcdService`, recovered from their decompiled code; no open-source driver had tried
  them on a card before.

rgbctrl asks for the newer controller first, as Gigabyte's software does. Using the panel takes
two steps, both in the admin-only base config `%ProgramData%\rgbctrl\rgbctrl.json`:

1. `lcd` lets rgbctrl ask which controller the card has and which firmware it runs (and, on
   the older one, which screen it shows). These queries change nothing; the log says what
   answered (`GPU LCD found: ...`).

   ```json
   { "plugins": { "gigabyte_gpu": { "lcd": true } } }
   ```

2. `lcd_readout` also lets it send the commands that change what the panel shows: the overlay
   and its values, and the panel's power, built-in screen and colors (on the newer controller
   only with `lcd_screen` and the color keys, see below). Only add it once step 1 finds the
   panel.

   ```json
   { "plugins": { "gigabyte_gpu": { "lcd": true, "lcd_readout": true } } }
   ```

   None of these commands writes the panel's flash, but they are not risk-free: the RTX 5090
   panel of CodeTorch's AorusLcd went dark twice after overlay commands, and came back after a
   full power-off (switching the power supply off) and, once, after an image upload, which
   Gigabyte's own software can also do.

The readouts, the seconds each one stays up, the built-in screen and its colors can go in
either file:

```json
{
  "plugins": {
    "gigabyte_gpu": {
      "lcd_metrics": ["temp", "load", "fan", "power"],
      "lcd_seconds": 4
    }
  }
}
```

- `lcd_metrics` accepts `temp`, `clock`, `load`, `fan`, `vram_clock`, `vram` and `power`.
  The panel also has an FPS field, which rgbctrl cannot fill.
- `lcd_screen` (1, 2 or 3; anything else is ignored with a warning) picks one of the three
  built-in screens ("Enthusiast 01" to "03" in Gigabyte's software). The older controller
  switches to it (screen 1 without the key). The newer one cannot report its screen, so rgbctrl
  could not switch it back: without `lcd_screen` it puts the overlay on the screen the panel
  shows (over the Chibi Time mascot on the tested card, where it did not appear), and only
  with `lcd_screen` does it switch the panel on and change the screen.
- `lcd_seconds` is 1 to 60, but the newer controller shows a reading at most 10 s.
- On the newer controller, the built-in screens draw the readings and the artwork beside them
  (the eagle of screen 1, the helmet of screen 2, the three heads of screen 3) in colors of
  their own, a rainbow wave on the tested card, over a white background that no command
  changes. On the screen that `lcd_screen` picks, `lcd_color` (`"#RRGGBB"`) sets the readings
  to a static color and `lcd_logo_color` the artwork, which the background color should hide.
  Without them the panel keeps its colors, which rgbctrl cannot read back. The overlay on
  other screens also takes `lcd_color`, and is white without it. The older controller ignores
  both keys. For black readings without artwork on screen 1:

  ```json
  {
    "plugins": {
      "gigabyte_gpu": { "lcd_screen": 1, "lcd_color": "#000000", "lcd_logo_color": "#FFFFFF" }
    }
  }
  ```

  A black background would take a custom picture uploaded into the panel's flash, which
  rgbctrl does not do.

- The panel shows only what rgbctrl sends. When rgbctrl stops feeding it (`rgbctrl stop`, or a
  config change that turns `lcd` or `lcd_readout` off or reloads the plugin), the overlay goes.
  The older controller then returns to the screen it showed before, switching off again if it
  was off. A screen or colors that rgbctrl set on the newer one stay until the card loses
  power; Gigabyte's software treats such changes as unsaved, so the panel should then show
  the screen and colors saved in it again. When the process is killed, the last values stay
  on the panel.
- Each update holds the card's I2C bus for a few milliseconds, about 25 ms on the newer
  controller. The older controller gets an update when the shown values change visibly and at
  least every 30 s. The newer one gets one every second, as Gigabyte's service sends them,
  because how long it keeps values without an update is not known. A game can hitch briefly
  when an update is sent, as some users report with Gigabyte's own software. Remove
  `lcd_readout` if that bothers you.
- With `lcd` on, rgbctrl detects the LCD card's lighting controller without reading from it.
  Once a panel answers, all I2C traffic to its card, lighting included, runs at the speed
  Gigabyte's software uses for that panel: 100 kHz for the newer controller, 400 kHz for the
  older. Until then the card's lighting runs at 100 kHz, and each probe asks 0x76 at 100 kHz
  and 0x61 at 400 kHz.

## Commands

```
rgbctrl run [--config <path>] [--allow-insecure-install]
rgbctrl apply [--config <path>] [--allow-insecure-install]
rgbctrl list [--config <path>] [--allow-insecure-install]
rgbctrl stop
rgbctrl check-install [--dir <path>]
rgbctrl version
rgbctrl help
```

Exit codes: 0 ok; 1 usage or configuration error (`apply` refuses to touch any lighting when a
configuration file cannot be used; `apply` and `list` also exit 1 when a zone setting is
invalid, after doing their work); 2 another instance is running (for `stop`: nothing
running was reachable); 3 internal error; 4 the install folder is not admin-only while
running elevated (or `check-install` found an install problem); 5 `check-install` found a base
config folder or file that exists but is not admin-only.

Only one instance runs at a time (`run`, `apply` and `list` all take the machine-wide
instance lock), so stop the resident instance before using `apply` or `list`.

## Diagnostics

- The log is `rgbctrl.log` next to `rgbctrl.exe` (elevated and SYSTEM runs always log there,
  because the folder is verified to be admin-only). Unelevated runs fall back to
  `%LOCALAPPDATA%\rgbctrl\` when the program folder is not writable. The file is rotated to
  `rgbctrl.log.1` at `log.max_size_kb`; if another program holds the log open so it cannot be
  renamed, the log is copied to `rgbctrl.log.1` and then emptied. If the copy fails too,
  nothing is emptied: rotation is retried every 60 s and the file never grows beyond twice
  that size (dropped warnings and errors then go to the Windows Event Log when there is no
  console). If the log file cannot be opened, rgbctrl retries every 5 s and keeps the messages
  in memory meanwhile; without a console, warnings and errors then go to the Windows Event Log.
- `log.level` `debug` (the default) records every probe and response; `trace` also records
  every frame. Warnings and errors are also printed to the console.
- Problems before the log can be opened go to stderr, and to the Windows Event Log (source
  `rgbctrl`) when there is no console, for example when the scheduled task cannot start.
- The banner at the top of every run lists the version, mode, paths, Windows build,
  privileges, the install check, the PawnIO driver, every plugin and device, and both config
  files with their status.

## Security model

Plugins run inside rgbctrl with its privileges, and some of them talk to the SMBus and PCI
configuration space through PawnIO. When rgbctrl runs elevated or as SYSTEM it therefore
refuses to start (exit 4) unless its own folder, `plugins\`, `pawnio\`, every DLL and module in
them and every parent folder are owned by SYSTEM, Administrators or TrustedInstaller and cannot
be modified by anyone else (`--allow-insecure-install` overrides this for development only).
It never reads configuration from its own folder. The user config file is treated as
untrusted when elevated: it is opened without following links or junctions anywhere in its
path, a `plugins` section with more than 256 entries is ignored, and it can only make the
privileged keys more restrictive; those keys (`enabled`, `persist`, `extra_ids`,
`sudokoo_sk700v.exclusive`, `gigabyte_gpu.lcd` and `gigabyte_gpu.lcd_readout`) take effect
from the admin-only base file only. PawnIO modules are checked against pinned SHA-256 hashes
before they are loaded.

## Documentation

- `docs\configuration.md`: configuration files, every key, effects, engines, reload.
- `docs\devices.md`: devices, zones, effects, discovery transactions, conflicts.
- `docs\plugin-abi.md`: the plugin ABI, the Zig SDK, the C example, and the terminology.

## Known limitations

- Images, text and GIFs on the RTX 5080 LCD, Super I/O fan control, the Keychron wireless
  modes (2.4 GHz dongle and Bluetooth), the Apex Pro's OLED screen and DDR5 hardware effects are
  not implemented.
- The Apex Pro's stored lighting (set with SteelSeries GG) cannot be changed: rgbctrl only sends
  it host frames, so until rgbctrl applies the zone the keyboard shows the stored lighting.
  Whether the keyboard keeps rgbctrl's colors through its own idle timeout is untested. Other
  Apex models are not supported.
- The GPU LCD readout supports only the RTX 5080 AORUS MASTER ICE. The older controller's
  protocol was confirmed on that card by an open-source driver, which draws the overlay on an
  uploaded image; that the overlay also works on the built-in screens is documented only for the
  RTX 5090 MASTER. The newer controller gets the commands of Gigabyte's software, which no
  driver outside it had sent before rgbctrl.
- The SK700V display has no field for fan speed; it shows temperature, power, load and
  frequency.
- The motherboard's `io_cover` and `chipset` zones are single-color in rgbctrl, although they
  are addressable LED strips (`docs\devices.md`), so a host effect such as `rainbow` shows one
  color across the whole zone.
- On the X870E AORUS PRO ICE the I/O cover once stopped following color changes and stayed on
  the first new color, while `persist` was saving to flash within 30 ms of each change; a
  reboot cleared it. rgbctrl now saves only after a device's effects have been unchanged for
  60 s. If a zone still stops responding, reboot the PC.
- After a cold boot, the same board left its I/O cover dark until the next restart when rgbctrl
  wrote to it in the first seconds after Windows started (every other zone took the writes),
  and lit it when the same writes came minutes later. So in `run` the motherboard's lighting
  waits until Windows has been running 300 s since it started or last woke from sleep or
  hibernation, a power-on with Fast Startup included (`boot_delay_seconds` in
  `docs\devices.md`); the board shows its own effect until then. `apply` leaves the
  motherboard alone during that time. Why the controller needs the wait, and how long exactly,
  is not known.

## License

No license has been chosen for this project yet.
