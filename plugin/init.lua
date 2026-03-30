local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

-- Default configuration
local config = {
  workspace_path = wezterm.home_dir .. "/.local/share/wezterm/workspaces.json",
}

--- Read file contents, returns nil on failure
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

--- Write string to file, returns true on success
local function write_file(path, content)
  local f = io.open(path, "w")
  if not f then
    wezterm.log_error("workspace-manager: failed to open file for writing: " .. path)
    return false
  end
  f:write(content)
  f:close()
  return true
end

--- Ensure parent directory exists
local function ensure_dir(path)
  local dir = path:match("(.+)/[^/]+$")
  if dir then
    os.execute("mkdir -p " .. wezterm.shell_quote_arg(dir))
  end
end

--- Load all workspaces from the JSON file
local function load_workspaces_from_file()
  local content = read_file(config.workspace_path)
  if not content or content == "" then
    return {}
  end
  local ok, data = pcall(wezterm.json_parse, content)
  if not ok or type(data) ~= "table" then
    wezterm.log_error("workspace-manager: failed to parse workspaces file")
    return {}
  end
  return data.workspaces or {}
end

--- Save workspaces array to the JSON file
local function save_workspaces_to_file(workspaces)
  ensure_dir(config.workspace_path)
  local json = wezterm.json_encode({ workspaces = workspaces })
  return write_file(config.workspace_path, json .. "\n")
end

--- Get cwd from a pane as a string (file:// URI or nil)
local function get_pane_cwd(pane)
  local cwd_url = pane:get_current_working_dir()
  if not cwd_url then
    return nil
  end
  if type(cwd_url) == "string" then
    return cwd_url
  end
  return tostring(cwd_url)
end

--- Recursively apply a tree node to a pane
local function apply_tree(pane, node, tab_cwd)
  if node.children and #node.children == 2 then
    -- Split node: split the pane, then recurse into both halves
    local direction = node.split == "horizontal" and "Right" or "Bottom"
    local split_opts = {
      direction = direction,
      size = 1.0 - node.ratio,
    }
    if tab_cwd then
      split_opts.cwd = tab_cwd
    end
    local new_pane = pane:split(split_opts)
    apply_tree(pane, node.children[1], tab_cwd)
    apply_tree(new_pane, node.children[2], tab_cwd)
  else
    -- Leaf node
    if node.cwd then
      local path = node.cwd:gsub("^file://[^/]*", "")
      pane:send_text("cd " .. wezterm.shell_quote_arg(path) .. " && clear\n")
    end
    if node.cmd then
      pane:send_text(node.cmd .. "\n")
    end
  end
end

--- Apply a single workspace to the current window
local function apply_workspace(gui_window, _, workspace)
  local mux_window = gui_window:mux_window()

  -- Close all existing tabs except the first one
  local existing_tabs = mux_window:tabs()
  for i = #existing_tabs, 2, -1 do
    existing_tabs[i]:activate()
    gui_window:perform_action(act.CloseCurrentTab({ confirm = false }), mux_window:active_pane())
  end

  local tabs = workspace.tabs or {}
  if #tabs == 0 then
    wezterm.log_info("workspace-manager: workspace has no tabs")
    return
  end

  for tab_idx, tab_def in ipairs(tabs) do
    local tab_cwd = nil
    if tab_def.tree then
      -- Find first leaf cwd for spawn_tab
      local function find_first_cwd(node)
        if node.children then
          return find_first_cwd(node.children[1])
        end
        return node.cwd
      end
      tab_cwd = find_first_cwd(tab_def.tree)
    end

    local tab, first_pane
    if tab_idx == 1 then
      tab = mux_window:active_tab()
      first_pane = tab:active_pane()
    else
      local spawn_args = {}
      if tab_cwd then
        local path = tab_cwd:gsub("^file://[^/]*", "")
        spawn_args.cwd = path
      end
      tab, first_pane, _ = mux_window:spawn_tab(spawn_args)
    end

    if tab_def.title then
      tab:set_title(tab_def.title)
    end

    if tab_def.tree then
      apply_tree(first_pane, tab_def.tree, tab_cwd and tab_cwd:gsub("^file://[^/]*", "") or nil)
    end
  end

  -- Activate the first tab and its first pane
  local final_tabs = mux_window:tabs()
  if #final_tabs > 0 then
    final_tabs[1]:activate()
    local panes = final_tabs[1]:panes()
    if #panes > 0 then
      panes[1]:activate()
    end
  end

  wezterm.log_info("workspace-manager: applied workspace '" .. workspace.name .. "'")
end

--- Build a binary split tree from a list of panes with position info.
--- Each pane_entry has: left, top, width, height, pane (the Pane object)
local function build_tree(pane_entries)
  if #pane_entries == 1 then
    -- Leaf node
    local entry = pane_entries[1]
    return {
      cwd = get_pane_cwd(entry.pane),
    }
  end

  -- Find the bounding box
  local min_left = math.huge
  local min_top = math.huge
  local max_right = 0
  local max_bottom = 0
  for _, e in ipairs(pane_entries) do
    min_left = math.min(min_left, e.left)
    min_top = math.min(min_top, e.top)
    max_right = math.max(max_right, e.left + e.width)
    max_bottom = math.max(max_bottom, e.top + e.height)
  end

  local total_width = max_right - min_left
  local total_height = max_bottom - min_top

  -- Try to find a vertical split line (horizontal split = left/right children).
  -- A valid split column is one where no pane straddles it, and both sides
  -- have at least one pane.
  local function try_horizontal_split()
    -- Collect all unique left edges (excluding the bounding box left)
    local candidates = {}
    local seen = {}
    for _, e in ipairs(pane_entries) do
      if e.left > min_left and not seen[e.left] then
        seen[e.left] = true
        table.insert(candidates, e.left)
      end
    end
    table.sort(candidates)

    for _, split_col in ipairs(candidates) do
      local left_group = {}
      local right_group = {}
      local valid = true
      for _, e in ipairs(pane_entries) do
        local pane_right = e.left + e.width
        if pane_right <= split_col then
          table.insert(left_group, e)
        elseif e.left >= split_col then
          table.insert(right_group, e)
        else
          -- Pane straddles the split line
          valid = false
          break
        end
      end
      if valid and #left_group > 0 and #right_group > 0 then
        local ratio = (split_col - min_left) / total_width
        return ratio, left_group, right_group
      end
    end
    return nil
  end

  -- Try to find a horizontal split line (vertical split = top/bottom children)
  local function try_vertical_split()
    local candidates = {}
    local seen = {}
    for _, e in ipairs(pane_entries) do
      if e.top > min_top and not seen[e.top] then
        seen[e.top] = true
        table.insert(candidates, e.top)
      end
    end
    table.sort(candidates)

    for _, split_row in ipairs(candidates) do
      local top_group = {}
      local bottom_group = {}
      local valid = true
      for _, e in ipairs(pane_entries) do
        local pane_bottom = e.top + e.height
        if pane_bottom <= split_row then
          table.insert(top_group, e)
        elseif e.top >= split_row then
          table.insert(bottom_group, e)
        else
          valid = false
          break
        end
      end
      if valid and #top_group > 0 and #bottom_group > 0 then
        local ratio = (split_row - min_top) / total_height
        return ratio, top_group, bottom_group
      end
    end
    return nil
  end

  -- Try horizontal (left/right) split first
  local h_ratio, h_left, h_right = try_horizontal_split()
  if h_ratio then
    return {
      split = "horizontal",
      ratio = math.floor(h_ratio * 100 + 0.5) / 100,
      children = {
        build_tree(h_left),
        build_tree(h_right),
      },
    }
  end

  -- Try vertical (top/bottom) split
  local v_ratio, v_top, v_bottom = try_vertical_split()
  if v_ratio then
    return {
      split = "vertical",
      ratio = math.floor(v_ratio * 100 + 0.5) / 100,
      children = {
        build_tree(v_top),
        build_tree(v_bottom),
      },
    }
  end

  -- Fallback: should not happen with a valid pane layout.
  -- Return first pane as a leaf.
  wezterm.log_error("workspace-manager: could not determine split for " .. #pane_entries .. " panes")
  return {
    cwd = get_pane_cwd(pane_entries[1].pane),
  }
end

--- Capture the current window state as a workspace table
local function capture_current_workspace(gui_window, workspace_name)
  local mux_window = gui_window:mux_window()
  local tabs_info = mux_window:tabs_with_info()
  local tabs = {}

  for _, tab_info in ipairs(tabs_info) do
    local tab = tab_info.tab
    local panes_info = tab:panes_with_info()

    -- Build pane entries for the tree builder
    local entries = {}
    for _, pi in ipairs(panes_info) do
      table.insert(entries, {
        left = pi.left,
        top = pi.top,
        width = pi.width,
        height = pi.height,
        pane = pi.pane,
      })
    end

    local tree = build_tree(entries)

    table.insert(tabs, {
      title = tab:get_title(),
      tree = tree,
    })
  end

  return {
    name = workspace_name,
    tabs = tabs,
  }
end

--- Override or append a workspace in the workspaces list by name
local function upsert_workspace(workspaces, new_workspace)
  for i, l in ipairs(workspaces) do
    if l.name == new_workspace.name then
      workspaces[i] = new_workspace
      return workspaces
    end
  end
  table.insert(workspaces, new_workspace)
  return workspaces
end

--- Configure the plugin
function M.setup(opts)
  opts = opts or {}
  if opts.workspace_path then
    config.workspace_path = opts.workspace_path
  end
end

--- Returns an action that shows a picker to select and apply a workspace
function M.apply_workspace()
  return wezterm.action_callback(function(window, pane)
    local workspaces = load_workspaces_from_file()

    -- Build a map of saved workspace names
    local workspace_map = {}
    for _, workspace in ipairs(workspaces) do
      workspace_map[workspace.name] = workspace
    end

    -- Collect workspace names
    local workspace_set = {}
    for _, name in ipairs(wezterm.mux.get_workspace_names()) do
      workspace_set[name] = true
    end

    -- Build a unified, deduplicated list of names
    local seen = {}
    local names = {}
    for _, workspace in ipairs(workspaces) do
      if not seen[workspace.name] then
        seen[workspace.name] = true
        table.insert(names, workspace.name)
      end
    end
    for name, _ in pairs(workspace_set) do
      if not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end

    if #names == 0 then
      window:toast_notification("Workspace Manager", "No workspaces or workspaces found", nil, 4000)
      return
    end

    local NEW_WORKSPACE_ID = "\0new"

    local choices = {}
    for _, name in ipairs(names) do
      local has_workspace = workspace_map[name] ~= nil
      local label
      if has_workspace then
        local tab_count = workspace_map[name].tabs and #workspace_map[name].tabs or 0
        local description = tab_count .. " tab" .. (tab_count ~= 1 and "s" or "")
        if has_workspace then
          label = name .. "  (" .. description .. ", workspace active)"
        else
          label = name .. "  (" .. description .. ")"
        end
      else
        -- Workspace only: dim with a note
        label = wezterm.format({
          { Attribute = { Intensity = "Half" } },
          { Text = name .. "  (workspace only)" },
        })
      end
      table.insert(choices, {
        id = name,
        label = label,
      })
    end

    table.insert(choices, {
      id = NEW_WORKSPACE_ID,
      label = wezterm.format({
        { Attribute = { Intensity = "Bold" } },
        { Text = "+ New workspace" },
      }),
    })

    window:perform_action(
      act.InputSelector({
        action = wezterm.action_callback(function(inner_window, inner_pane, id, label)
          if not id and not label then
            return
          end

          -- New workspace: prompt for a name then switch
          if id == NEW_WORKSPACE_ID then
            inner_window:perform_action(
              act.PromptInputLine({
                description = "New workspace name:",
                action = wezterm.action_callback(function(prompt_window, prompt_pane, name)
                  if not name or name == "" then
                    return
                  end
                  prompt_window:perform_action(act.SwitchToWorkspace({ name = name }), prompt_pane)
                end),
              }),
              inner_pane
            )
            return
          end

          -- If a workspace with this name already exists, just switch to it
          if workspace_set[id] then
            inner_window:perform_action(act.SwitchToWorkspace({ name = id }), inner_pane)
            return
          end

          -- No existing workspace: create one, switch to it, and apply the workspace
          local workspace = workspace_map[id]
          if not workspace then
            return
          end
          inner_window:perform_action(act.SwitchToWorkspace({ name = id }), inner_pane)
          -- Defer workspace application so the workspace switch completes first
          wezterm.time.call_after(0.1, function()
            -- Walk all gui windows to find the one now on our workspace
            for _, gui_win in ipairs(wezterm.gui.gui_windows()) do
              if gui_win:mux_window():get_workspace() == id then
                apply_workspace(gui_win, gui_win:mux_window():active_pane(), workspace)
                break
              end
            end
          end)
        end),
        title = "Select workspace",
        choices = choices,
        fuzzy = true,
        fuzzy_description = "Select workspace: ",
      }),
      pane
    )
  end)
end

--- Save the current workspace under the given name
local function do_save_workspace(gui_window, name)
  local workspace = capture_current_workspace(gui_window, name)
  local workspaces = load_workspaces_from_file()
  workspaces = upsert_workspace(workspaces, workspace)
  if save_workspaces_to_file(workspaces) then
    gui_window:toast_notification("Workspace Manager", "Saved workspace '" .. name .. "'", nil, 4000)
  else
    gui_window:toast_notification("Workspace Manager", "Failed to save workspace", nil, 4000)
  end
end

--- Returns an action that saves the current window workspace using the active workspace name.
function M.save_workspace()
  return wezterm.action_callback(function(window, _)
    local name = window:mux_window():get_workspace()
    if not name or name == "" then
      window:toast_notification("Workspace Manager", "Could not determine workspace name", nil, 4000)
      return
    end
    do_save_workspace(window, name)
  end)
end

--- Returns an action that shows a picker to delete a workspace (and its workspace, if any)
function M.delete_workspace()
  return wezterm.action_callback(function(window, pane)
    local workspaces = load_workspaces_from_file()
    if #workspaces == 0 then
      window:toast_notification("Workspace Manager", "No workspaces to delete", nil, 4000)
      return
    end

    local choices = {}
    for _, workspace in ipairs(workspaces) do
      table.insert(choices, {
        id = workspace.name,
        label = workspace.name,
      })
    end

    window:perform_action(
      act.InputSelector({
        action = wezterm.action_callback(function(inner_window, _, id, label)
          if not id and not label then
            return
          end
          -- Remove from saved workspaces
          local new_workspaces = {}
          for _, l in ipairs(workspaces) do
            if l.name ~= id then
              table.insert(new_workspaces, l)
            end
          end
          if not save_workspaces_to_file(new_workspaces) then
            return
          end
          -- Delete the workspace with the same name, if it exists
          local workspace_names = wezterm.mux.get_workspace_names()
          for _, ws_name in ipairs(workspace_names) do
            if ws_name == id then
              -- Close all windows in that workspace
              for _, mux_win in ipairs(wezterm.mux.all_windows()) do
                if mux_win:get_workspace() == id then
                  for _, tab in ipairs(mux_win:tabs()) do
                    for _, p in ipairs(tab:panes()) do
                      p:send_text("exit\n")
                    end
                  end
                end
              end
              break
            end
          end
          inner_window:toast_notification("Workspace Manager", "Deleted workspace '" .. id .. "'", nil, 4000)
        end),
        title = "Delete workspace",
        choices = choices,
        fuzzy = true,
        fuzzy_description = "Delete workspace: ",
      }),
      pane
    )
  end)
end

return M
