# Configuration

rgbctrl reads JSON with two extensions: `//` and `/* */` comments, and trailing commas. A
file may be at most 1 MiB, nest at most 64 levels and must be valid UTF-8; an object may have at
most 4096 members and an array at most 8192 items. Errors are reported with line and column. A
duplicated key keeps its last value and logs a warning (at most 100 such warnings per file).

## Files and layers

| Layer | Path | Purpose |
|---|---|---|
| base | `%ProgramData%\rgbctrl\rgbctrl.json` | optional, admin-only; the only source of privileged keys when rgbctrl runs elevated or as SYSTEM |
| user | `--config <path>`, else `%LOCALAPPDATA%\rgbctrl\rgbctrl.json` | optional; normally holds the lighting |

The effective configuration is the base with the user layer merged over it: objects merge key
by key, arrays and plain values replace, and `null` removes a key. A layer that cannot be
parsed is ignored and the error is logged with its line and column; `apply` then exits with
code 1 without touching any lighting, and a resident `run` keeps its previous configuration
when a reload fails. rgbctrl never reads configuration from its own program folder;
`rgbctrl.example.json` there is only a template. The banner in the log and `rgbctrl list`
show both paths and whether each was used.

While rgbctrl runs resident it checks both files every second and reloads 300 ms after a
change settles. Only what changed is re-applied: log settings go to the logger, a plugin whose
own section changed is reopened, and lighting or `frame_rate` changes only update the affected
zones.

The settings window, `rgbctrl-gui.exe` (`docs\gui.md`), edits the same files in place and keeps
their comments. A resident rgbctrl reports what it found, the problems in these files and
which version of each file it uses in `rgbctrl.inventory.json` next to its log.

## Top-level keys

| Key | Default | Meaning |
|---|---|---|
| `log.file` | `rgbctrl.log` | log file name next to `rgbctrl.exe`: a letter or digit, then letters, digits, `_` or `-`, ending in `.log` (not a device name such as `nul.log`) |
| `log.level` | `debug` | `error`, `warn`, `info`, `debug` or `trace` |
| `log.max_size_kb` | `1024` | 64..65536; the log is rotated to `<name>.1` when larger. If another program keeps the log open so it cannot be renamed, the log is copied to `<name>.1` and then emptied; if the copy fails too, nothing is emptied, rotation is retried every 60 s and lines beyond twice this size are dropped (and counted) until it works, with dropped warnings and errors sent to the Windows Event Log when there is no console |
| `frame_rate` | `30` | 1..60 frames per second for host-animated effects |
| `lighting` | `{}` | see below |
| `plugins.<name>` | `{}` | per-plugin settings, passed to that plugin |

Unknown keys are reported with a suggestion when a known key is within two edits
("unknown key "lightning"; did you mean "lighting"?").

## Plugins

`plugins.<name>` holds the settings of one plugin. The host itself reads two of them:

- `enabled` (default `true`, or `false` for opt-in plugins such as `corsair_ddr5`): load and
  open the plugin.
- `persist` (default `false`): let rgbctrl save the applied hardware effects to device memory
  (see "Saving to device memory").

Everything else is interpreted by the plugin; `docs\devices.md` lists the keys of every
plugin. Changing a plugin's own keys reopens that plugin; `enabled` and `persist` take effect
without a reopen.

### Privileged keys

`plugins.<name>.enabled`, `plugins.<name>.persist`, `plugins.<name>.extra_ids`,
`plugins.sudokoo_sk700v.exclusive`, `plugins.gigabyte_gpu.lcd` and
`plugins.gigabyte_gpu.lcd_readout` widen what rgbctrl may touch. When rgbctrl runs elevated or
as SYSTEM, their value comes from the built-in default and then the base file only, and only
if the base file and its folder are admin-only (`rgbctrl check-install` shows the verdict).
The user file may still make them more restrictive (`enabled: false`, `persist: false`,
`lcd: false`, `lcd_readout: false`, `exclusive: true`, or a subset of the trusted
`extra_ids`); anything else, including `null`, is ignored with a warning. While elevated, the
user file is also opened without following links or junctions anywhere in its path, and an
untrusted `plugins` section (in the user file, or in a base file that is not admin-only) with
more than 256 entries is ignored as a whole with a warning. When rgbctrl runs unelevated both
files are trusted.

## Lighting

```json
"lighting": {
  "*":           { "*": { "effect": "static", "color": "#FFFFFF" } },
  "motherboard": { "argb1": { "leds": 30, "effect": "rainbow", "speed": 40 } }
}
```

`lighting.<device>.<zone>` is an effect specification. `<device>` is a device id from
`rgbctrl list` (for example `motherboard`, `gpu`, `keyboard`, `ram`) and `<zone>` a zone of
that device; `*` matches every device or every zone. For each zone, every key is taken from
the most specific level that sets it, in this order from least to most specific:
`*.*`, `*.<zone>`, `<device>.*`, `<device>.<zone>`. When two plugins report the same device id,
the device of the later plugin (in file-name order) is configured as `<plugin>.<id>`; both
names are logged.

| Key | Values | Default |
|---|---|---|
| `effect` | `off`, `static`, `breathing`, `flash`, `cycle`, `rainbow`, `gradient`, `none` | none: the zone is left untouched |
| `color` | `"#RRGGBB"` | |
| `colors` | 1..16 colors; within one level `colors` wins over `color` | `["#FFFFFF"]` |
| `speed` | 0..100 | 50 |
| `brightness` | 0..100 (0 turns the zone off) | 100 |
| `engine` | `auto`, `host`, `hardware` | `auto` |
| `leds` | LED count of a resizable zone (the ARGB headers) | the plugin's value (0 for ARGB headers) |
| `reverse` | `true` mirrors spatial effects | `false` |
| `led_colors` | 1..4096 colors, one per LED; LEDs beyond the list use `colors[0]` | |

Effects:

- `static`: `colors[0]`, or `led_colors` per LED (without an `effect`, `led_colors` alone
  means static).
- `gradient`: the colors spread across the zone from the first to the last LED.
- `breathing`: fades in and out; each period uses the next color.
- `flash`: on for half of the period, off for the other half; each period uses the next color.
- `cycle`: with one color the hue sweeps the whole wheel starting from that color; with more
  colors it blends from one to the next.
- `rainbow`: the full hue wheel across the zone, moving over time.
- `off`: black.

`speed` sets the period: 0 = 20 s, 10 = 12 s, 20 = 8 s, 30 = 5.5 s, 40 = 4 s, 50 = 3.2 s,
60 = 2.4 s, 70 = 1.8 s, 80 = 1.2 s, 90 = 0.8 s, 100 = 0.5 s, linear in between. All devices
share one clock, so the same effect with the same speed stays in step across devices.

### Engines

A zone can run an effect in the device itself (hardware) or have rgbctrl stream frames to
it (host). The hardware engine is possible when the device supports that effect, the number of
colors fits, no `led_colors` are set and a spatial effect (`rainbow`, `gradient`, `static`
with `led_colors`) is not reversed. The host engine is possible when the zone accepts frames.

- `auto`: hardware when possible, else host.
- `hardware`: hardware, else host with a warning.
- `host`: host, else hardware with a warning.

`off` uses the device's own off setting when it has one, else a black host frame. A zone
that neither engine can serve is left untouched with a warning. The chosen engine is logged
for every zone.

### Validation

Mistakes affect only the zone concerned and are logged with the JSON path: an unknown effect
or engine, 0 or more than 16 colors, an invalid color or a wrong value type leave that zone
untouched. Out-of-range `speed` and `brightness` are clamped with a warning, `leds` is clamped
to the zone maximum and ignored on fixed-size zones, `led_colors` with a non-static effect is
ignored, and a resizable zone with 0 LEDs gets a reminder to set `leds`. Device and zone
names that match nothing on this PC are reported with the closest match. `rgbctrl list`
prints all of these problems (and exits 1 when a zone setting is invalid) without changing
any lighting.

## Saving to device memory

Hardware effects normally live only until the device loses power. With
`plugins.<name>.persist: true` (a privileged key) a resident `run` asks the plugin to save
the current hardware settings of a device when all of these hold: a hardware effect was
applied since the last save, the device's hardware effects have not changed for 60 s, rgbctrl
has been running for at least 60 s, and the last save attempt of that device was at least 60 s
ago. Plugins refuse while saving would be unsafe
(the Keychron keyboard and the GPU while any of their zones receives host frames, and the
motherboard while its writes wait for `boot_delay_seconds` and for 60 s after them);
rgbctrl retries later and warns once when a device has not been saved for 10 minutes. `apply`,
`list` and stopping the scheduled task never save. Supported by `gigabyte_fusion2`,
`gigabyte_gpu` and `keychron`.

## Example

`rgbctrl.example.json` in the program folder configures every zone of the supported devices
and the SK700V display keys. Copy it to `%LOCALAPPDATA%\rgbctrl\rgbctrl.json` and edit it;
remove the devices you do not have or do not want to change. Its `ram` block only takes effect
after `corsair_ddr5` is enabled in the base file.

The privileged keys go into the base file `%ProgramData%\rgbctrl\rgbctrl.json` (created
admin-only by `scripts\install.ps1`, with an empty `plugins` object), for example:

```json
{
  "plugins": {
    "corsair_ddr5": { "enabled": true },
    "keychron": { "persist": true, "extra_ids": ["3434:0870"] },
    "gigabyte_fusion2": { "persist": true },
    "gigabyte_gpu": { "persist": true, "lcd": true }
  }
}
```
