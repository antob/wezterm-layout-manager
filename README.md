# wezterm-layout-manager

WezTerm plugin that loads and saves window layouts from a JSON file.

## Features

- **Apply layout**: Pick a layout from a fuzzy-searchable list and apply it to the current window
- **Save layout**: Capture the current window's tab/pane arrangement as a binary split tree
- **Delete layout**: Remove a saved layout from the JSON file

## Installation

```lua
local layout_mgr = wezterm.plugin.require("https://github.com/antob/wezterm-layout-manager")
```

## Configuration

```lua
-- Optional: configure the path to the layouts JSON file
-- Default: ~/.local/share/wezterm/layouts.json
layout_mgr.setup({
    layout_path = wezterm.home_dir .. "/.local/share/wezterm/layouts.json",
})
```

## Key Bindings

```lua
config.keys = {
    -- Apply a saved layout
    {
        key = "l",
        mods = "LEADER",
        action = layout_mgr.apply_layout(),
    },
    -- Save current layout
    {
        key = "l",
        mods = "LEADER|SHIFT",
        action = layout_mgr.save_layout(),
    },
    -- Delete a saved layout
    {
        key = "l",
        mods = "LEADER|CTRL",
        action = layout_mgr.delete_layout(),
    },
}
```

## JSON Format

Layouts are stored as binary split trees, matching WezTerm's internal pane model.

```json
{
  "layouts": [
    {
      "name": "code",
      "tabs": [
        {
          "title": "editor",
          "tree": {
            "split": "horizontal",
            "ratio": 0.46,
            "children": [
              {
                "split": "vertical",
                "ratio": 0.49,
                "children": [
                  { "cwd": "file:///home/user/Projects" },
                  { "cwd": "file:///home/user/Projects" }
                ]
              },
              { "cwd": "file:///home/user/Projects", "cmd": "vim" }
            ]
          }
        },
        {
          "title": "shell",
          "tree": {
            "cwd": "file:///home/user"
          }
        }
      ]
    }
  ]
}
```

### Node types

**Split node** (internal): has `split`, `ratio`, and `children` (always exactly 2).

| Field | Description |
|---|---|
| `split` | `"horizontal"` (left/right) or `"vertical"` (top/bottom) |
| `ratio` | Fraction (0.0-1.0) of space allocated to the first child |
| `children` | Array of exactly 2 child nodes |

**Leaf node** (pane): has `cwd` and optionally `cmd`.

| Field | Description |
|---|---|
| `cwd` | Working directory as `file://` URI (or `null`) |
| `cmd` | Command to run in the pane after creation (or `null`) |

A single-pane tab is just a leaf node as its `tree`.

### How saving works

The save function walks `panes_with_info()` for each tab and reconstructs the
binary split tree from pane positions (left, top, width, height). It finds split
lines where no pane straddles the boundary and recurses into each half.

### How applying works

The apply function walks the tree recursively. At each split node it calls
`pane:split()` with the correct direction and size ratio, then recurses into
both children. Leaf nodes set the working directory and run the command.
