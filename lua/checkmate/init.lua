---@class Checkmate
local M = {}

-- Internal plugin state
local _state = {
  initialized = false, -- Has setup been called?
}

-- Checks if the file matches the given pattern(s)
-- Note: All pattern matching is case-sensitive.
-- Users should include multiple patterns for case-insensitive matching.
function M.should_activate_for_buffer(bufnr, patterns)
  if not patterns or #patterns == 0 then
    return false
  end

  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)

  if not filename or filename == "" then
    return false
  end

  local norm_path = filename:gsub("\\", "/")
  local basename = vim.fn.fnamemodify(norm_path, ":t")
  local basename_no_ext = vim.fn.fnamemodify(basename, ":r")

  for _, pattern in ipairs(patterns) do
    -- Lua Pattern match (user-supplied pattern)
    local ok_path_match = pcall(string.match, norm_path, pattern)
    local ok_base_match = pcall(string.match, basename_no_ext, pattern)

    if ok_path_match and norm_path:match(pattern) == norm_path then
      return true
    end
    if ok_base_match and basename:match(pattern) == basename_no_ext then
      return true
    end

    -- Filename without extension (e.g. "daily" matching "daily.md")
    if not pattern:match("%.%w+$") and basename:match("%.md$") then
      if basename_no_ext == pattern then
        return true
      end
    end

    -- Fallback glob-like support: *.todo etc
    if pattern:find("*") then
      local lua_pattern = vim.pesc(pattern):gsub("%%%*", ".*")

      if norm_path:match(lua_pattern .. "$") then
        return true
      end
      if basename:match("^" .. lua_pattern .. "$") then
        return true
      end
      if basename_no_ext:match("^" .. lua_pattern .. "$") then
        return true
      end
    end
  end

  return false
end

---@param opts checkmate.Config?
M.setup = function(opts)
  local config = require("checkmate.config")
  opts = opts or {}

  if _state.initialized then
    M.stop()
  end

  config.setup(opts)

  _state.initialized = true

  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("checkmate_ft", { clear = true }),
    pattern = "markdown",
    callback = function(event)
      -- Check if this markdown file should activate Checkmate
      if M.should_activate_for_buffer(event.buf, config.options.files) then
        vim.schedule(function()
          M.start()
          require("checkmate.api").setup(event.buf)
        end)
      end
    end,
  })

  return config.options
end

-- Main loading function - loads all plugin components
function M.start()
  local config = require("checkmate.config")

  if config._state.running then
    return
  end

  if not config.options.enabled then
    return
  end

  local log = require("checkmate.log")
  log.setup()
  log.debug("Beginning plugin initialization", { module = "init" })

  config.start()

  require("checkmate.parser").setup()

  require("checkmate.highlights").setup_highlights()

  require("checkmate.commands").setup()

  if config.options.linter and config.options.linter.enabled ~= false then
    require("checkmate.linter").setup(config.options.linter)
  end

  M._setup_autocommands()

  config._state.running = true

  log.info("Checkmate plugin loaded successfully", { module = "init" })
end

-- Sets up all plugin autocommands (beyond the lazy detection ones)
function M._setup_autocommands()
  local augroup = vim.api.nvim_create_augroup("checkmate", { clear = true })

  -- Track active buffers for cleanup
  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      local bufnr = args.buf
      require("checkmate.config").unregister_buffer(bufnr)
      -- Reset any API state for this buffer
      require("checkmate.api")._debounced_process_buffer_fns[bufnr] = nil
      -- Clear the todo map cache for this buffer
      require("checkmate.parser").todo_map_cache[bufnr] = nil
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      M.stop()
    end,
  })
end

function M.stop()
  local config = require("checkmate.config")
  if not config.is_running() then
    return
  end

  config.stop()

  config._state.running = false

  require("checkmate.log").shutdown()
end

-- PUBLIC API --

---Toggle todo item(s) state under cursor or in visual selection
---
---To set a specific todo item to a target state, use `set_todo_item`
---@param target_state? checkmate.TodoItemState Optional target state ("checked" or "unchecked")
---@return boolean success
function M.toggle(target_state)
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")
  local highlights = require("checkmate.highlights")
  local config = require("checkmate.config")

  local profiler = require("checkmate.profiler")
  profiler.start("M.toggle")

  local smart_toggle_enabled = config.options.smart_toggle and config.options.smart_toggle.enabled

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If toggle() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      if smart_toggle_enabled then
        api.propagate_toggle(ctx, { todo_item }, transaction._state.todo_map, target_state)
      else
        ctx.add_op(api.toggle_state, todo_item.id, target_state)
      end
    end
    profiler.stop("M.toggle")
    return true
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  -- we go ahead a keep the parsed todo_map so that we can initialize the transaction below without it
  -- also having to discover_todos
  local todo_items, todo_map = api.collect_todo_items_from_selection(is_visual)

  transaction.run(bufnr, todo_map, function(_ctx)
    if smart_toggle_enabled then
      api.propagate_toggle(_ctx, todo_items, todo_map, target_state)
    else
      for _, item in ipairs(todo_items) do
        _ctx.add_op(api.toggle_state, item.id, target_state)
      end
    end
  end, function()
    highlights.apply_highlighting(bufnr)
  end)
  profiler.stop("M.toggle")
  return true
end

---Sets a given todo item to a specific state
---@param todo_item checkmate.TodoItem Todo item to set state
---@param target_state checkmate.TodoItemState
---@return boolean success
function M.set_todo_item(todo_item, target_state)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")

  if not todo_item then
    return false
  end

  local todo_id = todo_item.id
  local smart_toggle_enabled = config.options.smart_toggle and config.options.smart_toggle.enabled

  local ctx = transaction.current_context()
  if ctx then
    if smart_toggle_enabled then
      local todo_map = transaction._state.todo_map
      api.propagate_toggle(ctx, { todo_item }, todo_map, target_state)
    else
      ctx.add_op(api.set_todo_item, todo_id, target_state)
    end
    return true
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- If smart toggle is enabled, we need the todo_map
  local todo_map = smart_toggle_enabled and parser.get_todo_map(bufnr) or nil

  transaction.run(bufnr, todo_map, function(_ctx)
    if smart_toggle_enabled and todo_map then
      api.propagate_toggle(_ctx, { todo_item }, todo_map, target_state)
    else
      _ctx.add_op(api.set_todo_item, todo_id, target_state)
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)

  return true
end

--- Set todo item to checked state
---
--- See `toggle()`
---@return boolean success
function M.check()
  return M.toggle("checked")
end

--- Set todo item to unchecked state
---
--- See `toggle()`
---@return boolean success
function M.uncheck()
  return M.toggle("unchecked")
end

--- Create a new todo item
---@returns boolean success
function M.create()
  require("checkmate.api").create_todo()
  return true
end

--- Insert a metadata tag into a todo item(s) under the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
---@param value string? Value contained in the tag
---@return boolean success
function M.add_metadata(metadata_name, value)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local config = require("checkmate.config")
  local util = require("checkmate.util")

  local meta_props = config.options.metadata[metadata_name]
  if not meta_props then
    util.notify("Unknown metadata tag: " .. metadata_name, vim.log.levels.WARN)
    return false
  end

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If add_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      ctx.add_op(api.add_metadata, todo_item.id, metadata_name, value)
    end
    return true
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items, todo_map = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return false
  end

  -- Begin a transaction
  transaction.run(bufnr, todo_map, function(_ctx)
    for _, item in ipairs(todo_items) do
      _ctx.add_op(api.add_metadata, item.id, metadata_name, value)
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)
  return true
end

--- Remove a metadata tag from a todo item at the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
---@return boolean success
function M.remove_metadata(metadata_name)
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If remove_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      ctx.add_op(api.remove_metadata, todo_item.id, metadata_name)
    end
    return true
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items, todo_map = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return false
  end

  transaction.run(bufnr, todo_map, function(_ctx)
    for _, item in ipairs(todo_items) do
      _ctx.add_op(api.remove_metadata, item.id, metadata_name)
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)
  return true
end

---Removes all metadata from a todo item(s) under the cursor or include in visual selection
---@return boolean success
function M.remove_all_metadata()
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If remove_all_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      ctx.add_op(api.remove_all_metadata, todo_item.id)
    end
    return true
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items, todo_map = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return false
  end

  transaction.run(bufnr, todo_map, function(_ctx)
    for _, item in ipairs(todo_items) do
      _ctx.add_op(api.remove_all_metadata, item.id)
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)
  return true
end

--- Toggle a metadata tag on/off for todo item under the cursor or for each todo in the visual selection
---@param meta_name string Name of the metadata tag (defined in the config)
---@param custom_value string? (Optional) Value contained in tag. If nil, will attempt to get default value from get_value()
---@return boolean success
function M.toggle_metadata(meta_name, custom_value)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local util = require("checkmate.util")
  local profiler = require("checkmate.profiler")

  profiler.start("M.toggle_metadata")

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If toggle_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      ctx.add_op(api.toggle_metadata, todo_item.id, meta_name, custom_value)
    end
    profiler.stop("M.toggle_metadata")
    return true
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items, todo_map = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return false
  end

  transaction.run(bufnr, todo_map, function(_ctx)
    for _, item in ipairs(todo_items) do
      _ctx.add_op(api.toggle_metadata, item.id, meta_name, custom_value)
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)

  profiler.stop("M.toggle_metadata")
  return true
end

--- Lints the current Checkmate buffer according to the plugin's enabled custom linting rules
---
--- This is not intended to be a comprehensive Markdown linter
--- and could interfere with other active Markdown linters.
---
--- The purpose is to catch/warn about a select number of formatting
--- errors (according to CommonMark spec) that could lead to unexpected
--- results when using this plugin.
---
---@param opts? {bufnr?: integer, fix?: boolean} Optional parameters
---@return boolean success Whether lint was successful or failed
---@return table|nil diagnostics Diagnostics table, or nil if failed
function M.lint(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local api = require("checkmate.api")

  if not api.is_valid_buffer(bufnr) then
    return false, nil
  end

  local linter = require("checkmate.linter")
  local log = require("checkmate.log")
  local util = require("checkmate.util")

  local results = linter.lint_buffer(bufnr)

  if #results == 0 then
    util.notify("Linting passed!", vim.log.levels.INFO)
  else
    local msg = string.format("Found %d formatting issues", #results)
    util.notify(msg, vim.log.levels.WARN)
    log.warn(msg, log.levels.WARN)
    for i, issue in ipairs(results) do
      log.warn(string.format("Issue %d, row %d [%s]: %s", i, issue.lnum, issue.severity, issue.message))
    end
  end

  return true, results
end

---@class ArchiveOpts
---@field heading {title?: string, level?: integer}

--- Archive checked todo items to a special section
--- Rules:
--- - If a parent todo is checked, all its children will be archived regardless of state
--- - If a child todo is checked but its parent is not, the child will not be archived
---@param opts ArchiveOpts?
function M.archive(opts)
  opts = opts or {}
  local api = require("checkmate.api")
  return api.archive_todos(opts)
end

--- Open debug log
function M.debug_log()
  require("checkmate.log").open()
end

--- Clear debug log
function M.debug_clear()
  require("checkmate.log").clear()
end

--- Inspect todo item at cursor
function M.debug_at_cursor()
  local log = require("checkmate.log")
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1 -- normalize

  local extmark_id = 9001 -- Arbitrary unique ID for debug highlight

  -- Clear the previous debug highlight (just that one)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, config.ns, extmark_id)

  local item = parser.get_todo_item_at_position(bufnr, row, col, {
    search = { main_content = true },
  })

  if not item then
    util.notify("No todo item found at cursor", vim.log.levels.INFO)
    return
  end

  local msg = {
    ("Debug called at (0-index): %s:%s"):format(row, col),
    "Todo item at cursor:",
    ("  ID: %s"):format(item.id),
    ("  State: %s"):format(item.state),
    ("  List marker: [%s]"):format(util.get_ts_node_range_string(item.list_marker.node)),
    ("  Todo marker: [%d,%d] → %s"):format(
      item.todo_marker.position.row,
      item.todo_marker.position.col,
      item.todo_marker.text
    ),
    ("  Range: [%d,%d] → [%d,%d]"):format(
      item.range.start.row,
      item.range.start.col,
      item.range["end"].row,
      item.range["end"].col
    ),
    ("  Metadata: %s"):format(vim.inspect(item.metadata)),
  }

  -- Use native vim.notify here as we want to show this regardless of config.options.notify
  vim.notify(table.concat(msg, "\n"), vim.log.levels.DEBUG)

  vim.api.nvim_set_hl(0, "CheckmateDebugHighlight", { bg = "#3b3b3b" })

  vim.api.nvim_buf_set_extmark(bufnr, config.ns, item.range.start.row, item.range.start.col, {
    id = extmark_id,
    end_row = item.range["end"].row,
    end_col = item.range["end"].col,
    hl_group = "CheckmateDebugHighlight",
    priority = 9999, -- Ensure it draws on top
  })

  -- Auto-remove highlight after 3 seconds
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_del_extmark, bufnr, config.ns, extmark_id)
  end, 3000)
end

--- Print todo map
function M.debug_print_todo_map()
  local parser = require("checkmate.parser")
  local todo_map = parser.discover_todos(vim.api.nvim_get_current_buf())
  local sorted_list = require("checkmate.util").get_sorted_todo_list(todo_map)
  vim.notify(vim.inspect(sorted_list), vim.log.levels.DEBUG)
end

return M
