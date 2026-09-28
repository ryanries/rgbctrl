# Plugin ABI (version 1)

A plugin is a Windows x64 DLL in `plugins\` next to `rgbctrl.exe` that exports

```c
const rgbctrl_plugin *rgbctrl_plugin_entry(uint32_t host_abi_version);
```

`include\rgbctrl_plugin.h` is the authoritative definition; `sdk\abi.zig` mirrors it for Zig
plugins and checks the layout at compile time. Plugins can be written in any language that
can produce a DLL with the C calling convention.

## Loading

- rgbctrl loads every `*.dll` in `plugins\` in case-insensitive file-name order, with the DLL
  search path restricted to the plugin's folder and System32.
- It calls the entry with `RGBCTRL_ABI_VERSION`. Returning NULL means the plugin cannot serve
  that version. The returned table must stay valid while the DLL is loaded.
- The table is accepted when `struct_size` is at least the v1 size (128 bytes on x64),
  `abi_version` is between 1 and the host's version, `name` is 1..31 characters of `a-z`,
  `0-9` and `_` and unique among the loaded plugins, `version` is 1..31 printable characters,
  and `open`, `close`, `device_count` and `device_info` are present. Every rejection is logged
  and shown by `rgbctrl list`.
- Structures only grow by appending fields; `struct_size` tells the reader which fields exist.
  Fields beyond `struct_size` count as absent (zero or NULL).

## Plugin table

| Field | Meaning |
|---|---|
| `flags` | `RGBCTRL_PLUGIN_OPT_IN` (disabled until the configuration enables it), `RGBCTRL_PLUGIN_SENSOR_SOURCE` (ticked in every mode) |
| `tick_interval_ms` | 0 = never; values below 20 are raised to 20 |
| `transports` | `HID`, `SMBUS`, `I2C`, `OS`; HID plugins get hotplug rescans |
| `open`, `close` | create and destroy an instance |
| `device_count`, `device_info` | describe the devices of the instance |
| `set_zone_size` | resize a `RGBCTRL_ZONE_RESIZABLE` zone |
| `set_hw_effect` | run an effect in the device |
| `set_leds`, `flush` | host frames: `set_leds` may buffer, `flush` sends a device's frame |
| `tick` | periodic work (displays, sensors, keep-alives) |
| `rescan` | `HOTPLUG`, `RESUME` or `RECOVER`; returns `RGBCTRL_RESCAN_CHANGED`, 0 or an error |
| `persist` | save a device's current settings to its non-volatile memory |

A NULL function means the capability is absent. Status codes: `RGBCTRL_OK` (0),
`E_FAIL`, `E_UNSUPPORTED`, `E_ARGUMENT`, `E_DEVICE_LOST`, `E_ACCESS`, `E_BUSY`.

## Threading and lifetime

- Each plugin gets one dedicated host worker thread; every call into the plugin happens on
  it, so a plugin needs no locking of its own. Host services may be called from any thread.
- A call that takes longer than 2 s is logged (and again when it returns); other plugins keep
  running. At shutdown the host waits at most 3 s for a plugin and then exits without it.
- `config` nodes passed to `open` and every string returned by the `json_*` services are valid
  only during that `open` call; copy what you need.
- The results of `device_info` stay valid until the next `rescan`, `close` or `set_zone_size`;
  the host copies what it needs.

## Rules

- Discovery: `open` and `rescan` may only perform the identification transactions the
  plugin documents. They never change lighting, displays or device memory.
- `rescan(HOTPLUG)` and `rescan(RECOVER)` must not repeat identification writes on devices
  that are present and verified. `rescan(RESUME)` re-initializes devices after sleep.
- When a call returns `E_DEVICE_LOST`, the host stops calling the plugin's lighting and tick
  functions and calls `rescan(RECOVER)` after 5 s, doubling up to 5 minutes. Afterwards it
  re-applies every zone.
- Identity: device ids and zone names are 1..31 characters of `a-z`, `0-9` and `_`, unique
  within the plugin and stable across runs (never enumeration-order suffixes). If two plugins
  report the same device id, the later one is configured as `<plugin>.<id>`.
- Limits enforced by the host: at most 64 devices per plugin and 64 zones per device;
  `max_leds` is clamped to 4096 and `led_count` to `max_leds`; invalid devices are rejected
  with a log line.
- Units: `speed` and `brightness` are 0..100; `brightness` 0 never reaches `set_hw_effect` for
  an effect other than off. `led_x` gives LED positions 0..65535 for spatial effects; NULL
  means evenly spaced. `max_fps` 0 means no device limit.
- `close(RGBCTRL_CLOSE_KEEP)` leaves the outputs as they are; `close(RGBCTRL_CLOSE_EXIT)` is used
  only when a resident `run` ends (a display may blank itself). An output that is only right
  while the plugin feeds it, such as the GPU LCD readout of `gigabyte_gpu`, is removed on both.
- Persist: plugins never save on their own. The host decides when (see
  `docs\configuration.md`); the plugin returns `E_BUSY` when saving is unsafe right now and an
  error when the sequence did not complete.
- Modes: `host->mode` is `RUN`, `APPLY` or `LIST`. `LIST` calls no lighting functions and
  ticks only sensor sources; `APPLY` ticks only sensor sources.

## Host services

`rgbctrl_host` provides `log` (levels error..trace; the host adds time, level and the plugin
name), `now_ms` (milliseconds on the host clock shared by all plugins), `sensor_set` and
`sensor_get` (a shared table of named values with their age), and read-only JSON accessors
(`json_type`, `json_get`, `json_len`, `json_at`, `json_member`, `json_number`, `json_bool`,
`json_string`) for the plugin's section of the configuration. `host_dir` is the folder of
`rgbctrl.exe`.

Sensor names use `a-z`, `0-9`, `.` and `_` (up to 31 bytes). `cpu.temp`, `cpu.ccd<N>.temp` and
`cpu.power` belong to `amd_cpu`, `cpu.load`, `cpu.freq` and `mem.load` to `windows_metrics`,
and `gpu.temp`, `gpu.load`, `gpu.power`, `gpu.fan`, `gpu.freq`, `gpu.mem.freq` and
`gpu.mem.load` to `nvidia_gpu`; the other `cpu.`, `mem.` and `gpu.` names are reserved, and
every other plugin publishes under `<plugin name>.`.

## Writing a plugin in Zig

The SDK in `sdk\` (imported as `sdk`) contains the ABI mirror, Win32 declarations, HID,
PawnIO and NVAPI helpers, color math and text helpers that work without compiler_rt.
`plugins\sudokoo_sk700v` is a compact reference: `protocol.zig` holds the pure packet code with
byte-exact tests and `plugin.zig` the instance and ABI functions. Add the plugin name to
`plugin_names` in `build.zig`; `zig build plugin-<name>` builds it and `zig build test-<name>`
runs its tests.

## Writing a plugin in C

`examples\c_plugin\virtual_led.c` implements a virtual LED strip with every entry point. It is
built by `zig build examples` into `zig-out\bin\examples\virtual_led.dll`; copy it into
`plugins\` to try it. Its configuration keys inject faults for testing: `stall_ms` (every
flush takes that long), `stall_open_ms`, `fail_open`, `lose_after_frames`, `bad_device`,
`extra_device` and `hardware_only`. Any C compiler for Windows x64 works, for example
`zig cc -shared -I include -o virtual_led.dll examples\c_plugin\virtual_led.c`.

## Terminology

- host: `rgbctrl.exe`; it has no knowledge of any device.
- plugin: a DLL that implements this ABI for one family of devices.
- worker: the host thread dedicated to one plugin.
- device: something a plugin reports through `device_info`, addressed by its id.
- zone: an independently controllable group of LEDs of a device, addressed by its name.
- effect: `off`, `static`, `breathing`, `flash`, `cycle`, `rainbow` or `gradient`.
- hardware effect: an effect the device runs by itself after `set_hw_effect`.
- host effect: an effect rendered by the host and sent as frames with `set_leds` and `flush`.
- engine: where a zone's effect runs, hardware or host; chosen per zone.
- sensor: a named value in the host's shared table, such as `cpu.temp`.
- sensor source: a plugin flagged `RGBCTRL_PLUGIN_SENSOR_SOURCE` that publishes sensors.
- display device: a device that shows data rather than lighting, such as the SK700V.
- opt-in plugin: a plugin flagged `RGBCTRL_PLUGIN_OPT_IN`; disabled until enabled in the
  configuration.
- persist: saving a device's current settings to its non-volatile memory.
- binding generation: the set of zone specifications the host computed for one plugin's
  devices from one configuration; replaced as a whole when either changes.
- config layer: one of the two configuration files, base or user.
- privileged key: a configuration key that widens what rgbctrl may touch; honored only from
  the trusted base layer when rgbctrl runs elevated.
