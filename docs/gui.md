# rgbctrl Settings

`rgbctrl-gui.exe`, "rgbctrl Settings" in the Start menu, is an optional window for choosing the
lighting and the plugins without editing JSON. It is a separate program: rgbctrl works the same
with or without it, and the window never talks to the devices itself. It edits the
configuration files described in `docs\configuration.md`, and a running rgbctrl picks the
changes up the way it picks up any edit, within about two seconds.

## Starting it

`scripts\install.ps1` copies it to `%ProgramFiles%\rgbctrl` and adds "rgbctrl Settings" to the
Start menu of all users; `scripts\uninstall.ps1` removes both. It runs as the signed-in user,
without administrator rights. A build can also be started from `zig-out\bin\rgbctrl-gui.exe`.
Starting it while it is open brings the open window forward.

## The window

- The tree on the left holds **All devices**, every device rgbctrl found with its zones, and
  **Plugins**. Devices and zones that the settings mention but rgbctrl did not find stay in
  the tree, marked "not detected"; every effect is offered for them, since what they can show
  is not known.
- Selecting All devices, a device or a zone shows its lighting: **Effect**, **Colors**,
  **Speed**, **Brightness** and, for the ARGB headers, **LEDs**. Only the effects the zone can
  show are offered: a zone that only runs effects in the hardware lists only those.
- A device or zone whose effect is "Same as" the level above has no lighting of its own; the
  window shows, greyed out, what rgbctrl shows there, counting settings for every zone of a
  name (`lighting.*.<zone>`), which the tree has no entry for. Choosing an effect gives it
  settings of its own, shown in bold in the tree; choosing "Same as" again removes them. "Leave
  as it is" makes rgbctrl leave a zone alone, so the device keeps showing its own lighting.
- A color swatch opens the Windows color picker. **Add color** and **Remove color** change the
  number of colors within what the effect and the zone allow (a gradient needs two).
- An asterisk in the tree marks unsaved changes. **Save** writes them; **Revert** discards them
  and reads the files again. Closing the window with unsaved changes asks whether to save.
- The box at the bottom names your settings file and the administrator settings file, and lists
  the problems rgbctrl reported in them. The status line says whether rgbctrl is running and
  whether it applied the last save, and points out plugins that did not turn on or off as set.

## Plugins

The Plugins page lists every plugin rgbctrl loaded and its state. Clearing a check box turns a
plugin off: Save writes `"enabled": false` for it to your settings file. Checking the box again
removes that setting.

Opt-in plugins, such as `corsair_ddr5` for the DDR5 lighting, stay off unless the admin-only
base file `%ProgramData%\rgbctrl\rgbctrl.json` turns them on, whenever rgbctrl runs elevated or
as SYSTEM, as the scheduled task does. Turning one on therefore asks for administrator approval
when you save, and the Save button shows the shield. A second copy of rgbctrl-gui.exe then runs
as administrator for this edit alone:

1. It checks that the base folder and file are admin-only, as rgbctrl does before it uses them.
2. It sets `plugins.<name>.enabled` to `true` in the base file, keeping everything else.
3. It checks that the new file is admin-only too, and only then puts it in place of the old one.

Only a copy of rgbctrl Settings that only administrators can change, such as the installed one
in `%ProgramFiles%\rgbctrl`, asks for that approval: another program could take the place of a
copy in a folder you can write to just before Windows starts it as administrator. Run as
administrator, rgbctrl Settings makes the edit itself. When rgbctrl runs as you without
elevation, the setting goes to your own file instead, and no approval is needed. When the
approval is declined or the edit fails, the plugin stays checked, so you can save again.

## How Save writes the files

- Save writes your settings file, the one the running rgbctrl reads (its `--config`, else
  `%LOCALAPPDATA%\rgbctrl\rgbctrl.json`), and the base file only for the opt-in plugins above.
- Only the members that change are rewritten. Comments, blank lines, the order of the keys,
  trailing commas, line breaks and indentation stay as they were, and new members follow the
  layout of the members around them.
- A level with settings of its own gets `effect` and the keys that effect uses: `color` for one
  color or `colors` for more, `speed` and `brightness`. Keys the effect does not use are
  removed; "Same as" removes all of them, and an object left empty is removed too. `engine`,
  `reverse` and `led_colors` are never changed; the window mentions them where they are set.
- Every edit is read back with rgbctrl's own parser before it is kept, and the file is replaced
  in one step, so rgbctrl never reads a half-written file. When your file has a syntax error,
  the window shows where and saves nothing until it is fixed in a text editor.
- When a settings file changes on disk while you have unsaved changes, the window says so. Save
  then writes your changes on top of the changed file; Revert shows it.

## How it knows the devices

Only one program can talk to these devices at a time, so the window does not look for them. A
resident rgbctrl (`run`) writes what it found to `rgbctrl.inventory.json` next to its log
whenever that changes: its plugins and their states, every device and zone with its LED count
and hardware effects, the settings files it reads, the problems it found in them and which
version of each file it uses. `apply` and `list` do not write it.

The window reads the newest inventory in its own folder, `%ProgramFiles%\rgbctrl` and
`%LOCALAPPDATA%\rgbctrl`. When rgbctrl is not running, it shows the devices of the last run.
After a save it waits until the inventory reports the saved version of each file as applied,
or as refused: rgbctrl keeps running the configuration from before when it cannot use a file,
and the window then shows the error.

The inventory is JSON in format 1:

| Key | Meaning |
|---|---|
| `format` | 1; readers refuse other numbers and ignore unknown keys |
| `rgbctrl` | the version of rgbctrl |
| `account` | how rgbctrl runs: `system`, `elevated` or `standard` |
| `config.base`, `config.user` | `path`; `status`, as in the log banner; `privileged`, true when rgbctrl takes privileged keys such as `plugins.<name>.enabled` from the file (both files while rgbctrl runs as a standard user, else only an admin-only base file); `failed`, true when rgbctrl could not use the file the last time it read it; `applied_stamp`, the version of the file in use; `attempted_stamp`, the version read last |
| `config.kept_previous` | true when the last reload was refused and rgbctrl runs the configuration from before |
| `problems` | the configuration problems: `severity` (`warning` or `error`) and `message` |
| `plugins` | `name`, `version`, `file`, `transports`, `opt_in`, `sensors`, `enabled`, `state` (`active`, `disabled`, `opening`, `failed` or `closed`) |
| `devices` | `key` (the device id in `lighting`), `name`, `plugin`, `zones` |
| `devices[].zones` | `name`, `leds`, `max_leds`, `resizable`, `host_frames`, `global_brightness_only`, `hardware_effects`, `hardware_max_colors` |

A stamp is `"<last write time>:<size>"`, with the write time in 100 ns units since 1601 (UTC),
and empty when there was no file.

## Security

- rgbctrl Settings runs without administrator rights. The only elevated part is the helper copy
  for opt-in plugins: it accepts nothing but plugin names, writes nothing but the base file,
  and only when that file and its folder pass the same checks as for rgbctrl itself. The window
  starts the helper from its own program file, and only when administrators alone can change
  that file and every folder above it, as with the installed copy; any other copy refuses and
  points to the installed one. Two helpers never change the base file at the same time; a
  helper that cannot make sure of that changes nothing.
- Files are written through a handle to their folder, under a new name that is then renamed over
  the old file through its own handle, so nothing can swap either file in between. Run as
  administrator, the window refuses links and junctions anywhere in the path, as rgbctrl does
  when elevated, and only uses an inventory that only administrators can change, because Save
  writes to the settings file the inventory names.
- `rgbctrl check-install` also checks `rgbctrl-gui.exe` when it is in the program folder: a copy
  that other accounts could replace would ask for administrator approval on their behalf.

## Limitations

- The window edits effects, colors, speed, brightness, ARGB LED counts and which plugins run.
  Per-LED colors, engines, `reverse`, `frame_rate`, the log settings, `persist` and the
  plugins' own settings, such as the GPU LCD readout, still need a text editor
  (`docs\configuration.md` and `docs\devices.md`).
- There is no live preview: changes take effect when you save.
- The window does not start or stop rgbctrl.
