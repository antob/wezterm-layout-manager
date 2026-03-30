# wezterm-workspace-manager

WezTerm plugin that saves and restores window layouts, integrated with WezTerm workspaces.

## Features

- **Apply workspace**: Pick from saved workspaces and live workspaces in one fuzzy-searchable list. Switching to an active workspace just focuses it; loading a new layout creates a fresh workspace for it.
- **Save workspace**: Capture the current window's tab/pane arrangement using the active workspace name.
- **Delete workspace**: Remove a saved workspace and close its workspace if one exists.

## Installation

```lua
local workspace_mgr = wezterm.plugin.require("https://github.com/antob/wezterm-workspace-manager")
```

## Configuration

```lua
-- Optional: configure the path to the workspaces JSON file
-- Default: ~/.local/share/wezterm/workspaces.json
workspace_mgr.setup({
    workspaces_path = wezterm.home_dir .. "/.local/share/wezterm/workspaces.json",
})
```

## Key Bindings

```lua
config.keys = {
    -- Apply a saved workspace or switch to a workspace
    {
        key = "l",
        mods = "LEADER",
        action = workspace_mgr.apply_workspace(),
    },
    -- Save current workspace (uses active workspace name)
    {
        key = "l",
        mods = "LEADER|SHIFT",
        action = workspace_mgr.save_workspace(),
    },
    -- Delete a saved workspace (and its workspace)
    {
        key = "l",
        mods = "LEADER|CTRL",
        action = workspace_mgr.delete_workspace(),
    },
}
```

## Workflow

Layouts and workspaces share the same name. The typical flow is:

1. Switch to or create a workspace with `apply_workspace`.
2. Arrange your tabs and panes, then save with `save_workspace`. The active workspace name is used automatically.
3. When you reload WezTerm, `apply_workspace` recreates the workspace from the saved layout.

### Applying a workspace

The picker lists all saved workspaces plus all live workspaces, deduplicated:

- Items with a saved workspace show their tab count and are fully visible.
- Items that exist only as a live workspace (no saved workspace) appear dimmed.

On selection:

- If a workspace with that name is already running, the plugin switches to it without touching the layout.
- If no workspace exists, the plugin creates one with that name, switches to it, and applies the saved layout there.

### Saving a workspace

Saves the current window's tab/pane arrangement under the active workspace name. If a workspace with that name already exists it is overwritten.

### Deleting a workspace

Removes the workspace from the JSON file. If a workspace with the same name is running, all panes in it are closed, which destroys the workspace.

## JSON Format

Workspaces are stored as binary split trees, matching WezTerm's internal pane model.

```json
{
  "workspaces": [
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
