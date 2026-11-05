# Overview for Omarchy

A GNOME-style window overview for the [Omarchy](https://omarchy.org) shell: every window spread out as a live thumbnail, with your workspaces as tabs along the top.

## Install

```bash
omarchy plugin add https://github.com/galawaydude/omarchy-overview.git --enable
```

Bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + D", "Overview", { panel = "galawaydude.overview" })
```

Optionally, open it with a 3-finger swipe up (and close with a swipe down) in `~/.config/hypr/input.lua`:

```lua
hl.gesture({ fingers = 3, direction = "up", action = function() hl.dispatch(hl.dsp.exec_cmd("omarchy-shell shell summon galawaydude.overview '{}'")) end })
hl.gesture({ fingers = 3, direction = "down", action = function() hl.dispatch(hl.dsp.exec_cmd("omarchy-shell shell hide galawaydude.overview")) end })
```

## Using it

- **All** (the default) shows every window on every workspace. Each workspace has its own tab with a live preview; `+` is a new, empty one.
- **Click** a window to focus it. **Drag** it onto a tab to move it to that workspace.
- **Click** a tab to view it. **Double-click** it, or click empty space, to go there.
- **Type** to search windows on all workspaces.
- **Arrows** move between windows, stepping to the next tab at the left/right edge. **Enter** picks.
- **Tab** / **Shift+Tab** cycle tabs. **Esc** clears the search, then closes.

From the command line: `omarchy-shell shell toggle galawaydude.overview`.

## Notes

Edits to the QML need `omarchy restart shell`; hot-reload keeps the cached copy.
