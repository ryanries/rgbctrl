# Devices

Every device family is handled by its own plugin DLL in `plugins\`. This page lists, per
plugin, the device and zone names used in `lighting`, the supported effects, the plugin keys,
what the plugin sends to the hardware while discovering it (discovery never changes lighting,
displays or device memory), and known conflicts. `rgbctrl list` shows what was found on the
PC, and the log at `debug` level records every probe and response.

## gigabyte_fusion2: motherboard lighting (ITE IT5711)

- Match: USB HID 048D:5711, top-level collection usage page 0xFF89 / usage 0xCC, 64-byte
  feature report 0xCC. Opened exclusively.
- Device `motherboard`, zones:

| Zone | LEDs | Notes |
|---|---|---|
| `argb1`, `argb2`, `argb3` | 0..256, set with `leds` | 5 V ARGB headers; host frames and hardware effects |
| `rgb12v` | 1 | 12 V RGB header |
| `io_cover` | 1 | I/O shroud; OpenRGB drives it as an 8-LED strip on firmware 1.0.19.5, rgbctrl as one color |
| `chipset` | 1 | chipset heatsink; OpenRGB drives it as a 4-LED strip on firmware 1.0.19.5, rgbctrl as one color |

- Hardware effects: off, static, breathing, flash, cycle (1 color). Host frames on every zone
  (single-LED zones at most 15 frames per second).
- Discovery: `CC 60` then a feature read, `CC 61` then a feature read (firmware string and
  version, LED count classes, color order calibration and feature flags). A header whose
  calibration is all zero gets no capabilities and a warning. The firmware string, version and
  feature flags are logged at `debug`, and every feature report at `trace`.
- First lighting write after start, resume, reconnect or resizing: LampArray off when the
  firmware has it, beat mode off (`CC 31 00`), the LED count classes of the resized headers,
  and the mask of host-streamed headers. After start, resume or reconnect (not after resizing),
  every effect slot is also cleared between LampArray and beat mode (`CC 20`..`CC 27` and
  `CC 90`..`CC 92`, each an empty effect with no zones) and all zones are applied
  (`CC 28 FF 07`), as OpenRGB does when it opens the board. Without it the X870E AORUS PRO ICE
  (firmware 1.0.19.5) kept its factory rainbow on every zone although every write succeeded.
  Zones left untouched (`none`, the default) are cleared as well instead of keeping the effect
  stored on the board, so give every zone you want lit an effect.
- `persist`: `CC 47 01`, `CC 5E 00`.
- Conflicts: Gigabyte Control Center / RGB Fusion, OpenRGB, SignalRGB.

## gigabyte_gpu: graphics card lighting

- Match: NVIDIA GPUs whose full PCI identity (device and subsystem) is on the allowlist from
  the protocol research, over NVAPI I2C port 1. The RGB controller is probed only at 7-bit
  address 0x71 (older cards, 8-byte packets) or 0x75 (Blackwell, 64-byte packets); the LCD
  controller at 0x61 is never touched.
- Devices: the first allowlisted card (in PCI identity order) is `gpu`; any further card is
  `gpu_<subsystem id>` (for example `gpu_418c`), with `_2`, `_3` appended when that name is
  already taken. NVAPI transactions are serialized with `Local\rgbctrl.nvapi.i2c`; without it
  the plugin stays off.
  The device name is the card name reported by the driver. Zones of the AORUS RTX 5080 MASTER:
  `fan_left`, `fan_middle`, `fan_right` (8 LEDs each), `logo_side`, `logo_top`, `extra`
  (1 LED each). Older cards: `zones12` (2 LEDs), `zone3`, `zone4`, `zone5`.
- Hardware effects: off, static, breathing, flash, cycle, rainbow (1 color); `gradient` runs
  on the host. Host frames at most 10 per second.
- Discovery: Blackwell `10 01` (read 4 bytes: `01 01|02 01 xx`) and `11 01` (the reply echoes
  the subsystem id); older cards `AB 00 ...` (read 4 bytes starting with `AB`). A recovery
  after a failed write probes only the card that failed.
- `persist`: `AA` (older) or `13 01` (Blackwell); refused while any zone of the card receives
  host frames, because the card saves all zones at once.
- Not supported: the LCD on the MASTER card.
- Conflicts: Gigabyte Control Center, AORUS Engine, OpenRGB.

## corsair_ddr5: memory lighting (opt-in)

- Needs the PawnIO driver (`winget install namazso.PawnIO`), the `SmbusPIIX4` module in
  `pawnio\` and rgbctrl running elevated. Enabled only with
  `"plugins": {"corsair_ddr5": {"enabled": true}}` in the base file.
- Addresses 0x18..0x1F only, each through a guard: two identification reads, then two setup
  writes and the information block (vendor 0x1B1C, a known Corsair product, protocol version
  4 or later, valid checksum). Anything unexpected rejects the address for good.
- Device `ram`, zones `dimm1`, `dimm2`, ... in address order, 10 LEDs each, host frames only
  (at most 30 per second, sent only when they change). No hardware effects and no persist.
- Every transaction sequence holds the shared `Global\Access_SMBUS.HTP.Method` mutex, so
  tools that follow the same convention do not collide.
- Conflicts: Corsair iCUE, OpenRGB, any other SMBus RGB tool.

## keychron: keyboard lighting

- Match: VID 3434 with PID 0860, 0861 or 0862 (Q6 Max ANSI, ISO, JIS) or 0B60, 0B61 or 0B62
  (Q6 HE ANSI, ISO, JIS), raw HID collection 0xFF60 / 0x61, 32-byte reports. More ids with
  `extra_ids` (a privileged key, array of `"VVVV:PPPP"` strings). Opened exclusively; one
  request at a time.
- Wired only: connect the USB cable and set the keyboard's mode switch to cable. Over
  Bluetooth the device path has a different form, and the 2.4 GHz dongle has its own id, so
  neither matches.
- Another Keychron keyboard: find the interface `HID\VID_3434&PID_xxxx&MI_01` whose hardware
  ids include `HID_DEVICE_UP:FF60_U:0061` (Device Manager, or
  `Get-PnpDevice -PresentOnly | Where-Object InstanceId -match 'VID_3434'`) and add
  `"3434:xxxx"` to `extra_ids` in the base config. Such a keyboard needs firmware with the 0xA8
  protocol, because LED counts are built in only for the ids above.
- Device `keyboard`, zone `keys` (108, 109, 112 or 113 LEDs).
- Hardware effects (VIA channel 3): off, static, breathing, cycle, rainbow (1 color).
- Host frames need firmware with the 0xA8 per-key protocol (firmware 1.1 or later); the zone
  then accepts per-key colors but only one brightness for the whole keyboard, so darker keys
  show at the brightest key's level (a warning is logged once). Without 0xA8 the zone is
  hardware-only. At most 30 frames per second.
- Discovery: `01`, `A1`, `A2`, and with 0xA8 support `A8 01`, `A8 05` and the key map
  `A8 06` for rows 0..5. The firmware answers `A8 06` in the request buffer with one byte per
  matrix column (21 on the Q6), so the request is padded with 0xFF ("no LED") and every column
  of the reply is read.
- A discovery that fails for a reason other than a timeout (for example an incomplete key map)
  is logged once and retried only after the next device change (such as reconnecting the
  keyboard) or resume.
- A request that gets no reply within 250 ms aborts the sequence; the plugin then waits until
  the keyboard has been quiet for 1 s (at most 5 s) before it starts over; three failed
  restarts count as a lost device.
- `persist`: saves only the values that differ from what was last saved; refused while the
  zone receives host frames.
- Conflicts: Keychron Launcher (also as a browser page), VIA, OpenRGB.

## sudokoo_sk700v: cooler display

- Match: USB HID 381C:0003 with 64-byte output reports. Opened exclusively unless the
  privileged key `exclusive` is `false`.
- Device `cooler_display` with no zones. In `run` it sends a frame every second: CPU
  frequency (MHz), load (%), package power (W, plus a bar) and temperature (C or F). The
  display has no field for fan speed.
- Keys: `temp_sensor` (`cpu.temp`), `power_sensor` (`cpu.power`), `load_sensor` (`cpu.load`),
  `freq_sensor` (`cpu.freq`), `temperature_unit` (`C` or `F`), `power_bar_max_watts` (162,
  1..1000), `blank_on_exit` (`true`). A sensor that stops updating keeps its last value for
  10 s and then shows 0 (logged once).
- Temperature and power come from `amd_cpu` and need PawnIO and elevation; load and frequency
  come from `windows_metrics`.
- Conflicts: the vendor display software.

## amd_cpu: CPU sensors

- AMD family 17h or later, through the PawnIO `AMDFamily17` module (needs elevation).
- Publishes `cpu.temp` (Tctl), `cpu.ccd<N>.temp` for every valid CCD (starting at 0) and
  `cpu.power` (package power from the RAPL energy counter). Missing PawnIO, elevation or the
  module is logged once and nothing is published.

## windows_metrics: Windows sensors

- Publishes `cpu.load` (from GetSystemTimes), `cpu.freq` (performance counter
  "Processor Information(_Total)\Actual Frequency", with a fallback to frequency times
  performance) and `mem.load` (GlobalMemoryStatusEx).
- A `cpu.freq` sample that fails is skipped and the sensor keeps its last value; after 5
  failures in a row the counter query is reopened. Samples are taken at least 500 ms apart,
  because a rate counter read over a shorter window is noise. `cpu.freq` is switched off (and
  logged once) only when its counters cannot be opened at all.

## Sensors

Sensor names use `a-z`, `0-9`, `.` and `_`, up to 31 bytes. The standard names above belong
to their plugins; any other plugin publishes under its own name as a prefix
(`<plugin>.<name>`). A value older than 5 s counts as stale. `rgbctrl list` shows every
sensor, or why a standard sensor is missing.
