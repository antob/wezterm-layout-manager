local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

-- Default configuration
local config = {
  layout_path = wezterm.home_dir .. "/.local/share/wezterm/layouts.json",
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
    wezterm.log_error("layout-manager: failed to open file for writing: " .. path)
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

--- Load all layouts from the JSON file
local function load_layouts_from_file()
  local content = read_file(config.layout_path)
  if not content or content == "" then
    return {}
  end
  local ok, data = pcall(wezterm.json_parse, content)
  if not ok or type(data) ~= "table" then
    wezterm.log_error("layout-manager: failed to parse layouts file")
    return {}
  end
  return data.layouts or {}
end

--- Save layouts array to the JSON file
local function save_layouts_to_file(layouts)
  ensure_dir(config.layout_path)
  local json = wezterm.json_encode({ layouts = layouts })
  return write_file(config.layout_path, json .. "\n")
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

--- Apply a single layout to the current window
local function apply_layout(gui_window, pane, layout)
  local mux_window = gui_window:mux_window()

  -- Close all existing tabs except the first one
  local existing_tabs = mux_window:tabs()
  for i = #existing_tabs, 2, -1 do
    existing_tabs[i]:activate()
    gui_window:perform_action(act.CloseCurrentTab({ confirm = false }), mux_window:active_pane())
  end

  local tabs = layout.tabs or {}
  if #tabs == 0 then
    wezterm.log_info("layout-manager: layout has no tabs")
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

  wezterm.log_info("layout-manager: applied layout '" .. layout.name .. "'")
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
  wezterm.log_error("layout-manager: could not determine split for " .. #pane_entries .. " panes")
  return {
    cwd = get_pane_cwd(pane_entries[1].pane),
  }
end

--- Capture the current window state as a layout table
local function capture_current_layout(gui_window, layout_name)
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
    name = layout_name,
    tabs = tabs,
  }
end

--- Override or append a layout in the layouts list by name
local function upsert_layout(layouts, new_layout)
  for i, l in ipairs(layouts) do
    if l.name == new_layout.name then
      layouts[i] = new_layout
      return layouts
    end
  end
  table.insert(layouts, new_layout)
  return layouts
end

--- Configure the plugin
function M.setup(opts)
  opts = opts or {}
  if opts.layout_path then
    config.layout_path = opts.layout_path
  end
end

--- Returns an action that shows a picker to select and apply a layout
function M.apply_layout()
  return wezterm.action_callback(function(window, pane)
    local layouts = load_layouts_from_file()
    if #layouts == 0 then
      window:toast_notification("Layout Manager", "No layouts found in " .. config.layout_path, nil, 4000)
      return
    end

    local choices = {}
    for _, layout in ipairs(layouts) do
      local tab_count = layout.tabs and #layout.tabs or 0
      local description = tab_count .. " tab" .. (tab_count ~= 1 and "s" or "")
      table.insert(choices, {
        id = layout.name,
        label = layout.name .. "  (" .. description .. ")",
      })
    end

    window:perform_action(
      act.InputSelector({
        action = wezterm.action_callback(function(inner_window, inner_pane, id, label)
          if not id and not label then
            return
          end
          for _, layout in ipairs(layouts) do
            if layout.name == id then
              apply_layout(inner_window, inner_pane, layout)
              return
            end
          end
        end),
        title = "Select Layout",
        choices = choices,
        fuzzy = true,
        fuzzy_description = "Select layout: ",
      }),
      pane
    )
  end)
end

--- Save the current layout under the given name
local function do_save_layout(gui_window, name)
  local layout = capture_current_layout(gui_window, name)
  local layouts = load_layouts_from_file()
  layouts = upsert_layout(layouts, layout)
  if save_layouts_to_file(layouts) then
    gui_window:toast_notification("Layout Manager", "Saved layout '" .. name .. "'", nil, 4000)
  else
    gui_window:toast_notification("Layout Manager", "Failed to save layout", nil, 4000)
  end
end

local NEW_LAYOUT_ID = "__new_layout__"

--- Returns an action that saves the current window layout to the JSON file.
--- Shows existing layout names to overwrite, plus an option to create a new one.
function M.save_layout()
  return wezterm.action_callback(function(window, pane)
    local layouts = load_layouts_from_file()

    local choices = {}
    for _, layout in ipairs(layouts) do
      table.insert(choices, {
        id = layout.name,
        label = layout.name,
      })
    end
    table.insert(choices, {
      id = NEW_LAYOUT_ID,
      label = "+ New layout...",
    })

    window:perform_action(
      act.InputSelector({
        action = wezterm.action_callback(function(inner_window, inner_pane, id, label)
          if not id and not label then
            return
          end
          if id == NEW_LAYOUT_ID then
            -- Prompt for a new name
            inner_window:perform_action(
              act.PromptInputLine({
                description = wezterm.format({
                  { Attribute = { Intensity = "Bold" } },
                  { Foreground = { AnsiColor = "Fuchsia" } },
                  { Text = "Enter new layout name" },
                }),
                action = wezterm.action_callback(function(prompt_window, prompt_pane, line)
                  if not line or line == "" then
                    return
                  end
                  do_save_layout(prompt_window, line)
                end),
              }),
              inner_pane
            )
          else
            -- Overwrite existing layout
            do_save_layout(inner_window, id)
          end
        end),
        title = "Save Layout",
        choices = choices,
        fuzzy = true,
        fuzzy_description = "Save to layout: ",
      }),
      pane
    )
  end)
end

--- Returns an action that shows a picker to delete a layout
function M.delete_layout()
  return wezterm.action_callback(function(window, pane)
    local layouts = load_layouts_from_file()
    if #layouts == 0 then
      window:toast_notification("Layout Manager", "No layouts to delete", nil, 4000)
      return
    end

    local choices = {}
    for _, layout in ipairs(layouts) do
      table.insert(choices, {
        id = layout.name,
        label = layout.name,
      })
    end

    window:perform_action(
      act.InputSelector({
        action = wezterm.action_callback(function(inner_window, inner_pane, id, label)
          if not id and not label then
            return
          end
          local new_layouts = {}
          for _, l in ipairs(layouts) do
            if l.name ~= id then
              table.insert(new_layouts, l)
            end
          end
          if save_layouts_to_file(new_layouts) then
            inner_window:toast_notification("Layout Manager", "Deleted layout '" .. id .. "'", nil, 4000)
          end
        end),
        title = "Delete Layout",
        choices = choices,
        fuzzy = true,
        fuzzy_description = "Delete layout: ",
      }),
      pane
    )
  end)
end

return M
