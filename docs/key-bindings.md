# key bindings
(authored by agents unless marked 🧑)

Every recipe below runs one command: `~/.local/bin/mac-stt toggle`. Press once to record, again to stop and copy the text.

Notes for all tools:
- use the full path; hotkey tools usually do not load your shell's `PATH`
- macOS may attribute the microphone prompt to the tool that launched `mac-stt` (for example Hammerspoon); allow it there
- examples use F5 or ⌥Space; change the key to taste

## Shortcuts app (no extra install)

1. Shortcuts → New Shortcut → add "Run Shell Script" with `~/.local/bin/mac-stt toggle`.
2. Shortcut details (ⓘ) → "Add Keyboard Shortcut".

## AppleScript

The script:

```applescript
do shell script "$HOME/.local/bin/mac-stt toggle"
```

Ways to bind it to a key:
- Shortcuts: use "Run AppleScript" instead of "Run Shell Script" in the recipe above
- Automator: New → Quick Action, "Workflow receives: no input", add "Run AppleScript"; save, then System Settings → Keyboard → Keyboard Shortcuts → Services → General, assign a key
- FastScripts or any launcher that runs `.scpt` files: save the script to `~/Library/Scripts/` and assign a key there

Optional notification when done:

```applescript
set t to do shell script "$HOME/.local/bin/mac-stt toggle"
if t is not "" then display notification t with title "mac-stt"
```

## Karabiner-Elements

Add a rule in `~/.config/karabiner/karabiner.json` under `complex_modifications.rules` (or import it as a file in `~/.config/karabiner/assets/complex_modifications/`):

```json
{
  "description": "F5 toggles mac-stt",
  "manipulators": [{
    "type": "basic",
    "from": { "key_code": "f5" },
    "to": [{ "shell_command": "$HOME/.local/bin/mac-stt toggle" }]
  }]
}
```

## Hammerspoon

In `~/.hammerspoon/init.lua`:

```lua
hs.hotkey.bind({"alt"}, "space", function()
  hs.task.new(os.getenv("HOME") .. "/.local/bin/mac-stt", function(code, out, err)
    if code == 0 and out ~= "" then hs.alert.show(out) end
  end, {"toggle"}):start()
end)
```

`hs.task` runs asynchronously, so Hammerspoon does not freeze while the second press waits for transcription.

## skhd

In `~/.config/skhd/skhdrc`:

```
alt - space : ~/.local/bin/mac-stt toggle
```

## Raycast

Create a script command (Extensions → Script Commands), then assign a hotkey to it in Raycast settings:

```sh
#!/bin/sh
# @raycast.schemaVersion 1
# @raycast.title mac-stt toggle
# @raycast.mode silent
~/.local/bin/mac-stt toggle
```

## BetterTouchTool

Add a Keyboard Shortcut trigger with the action "Execute Terminal Command (Async, non-blocking)" and command `~/.local/bin/mac-stt toggle`.
