--- Shell terminal lifecycle and the run/exec pipeline.

local config = require("tarminal.config")
local errors = require("tarminal.errors")
local platform = require("tarminal.platform")
local state = require("tarminal.state")
local term = require("tarminal.term")
local util = require("tarminal.util")

local M = {}

local sh_quote = util.sh_quote

---@return integer row 0 when entirely blank
local function last_content_row(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i] ~= "" then
      return i
    end
  end
  return 0
end

local function get_or_create_shell_term()
  local buf = term.find_live_terminal("is_shell", true)
  if buf then
    return buf, term.ensure_window_for_buf(buf)
  end
  local win
  buf, win = term.open_shell_term("tarminal://shell")
  if not buf then
    return nil
  end
  vim.b[buf].is_shell = true
  term.enable_shell_integration(buf)
  return buf, win
end

function M.toggle()
  local buf = term.find_live_terminal("is_shell", true)
  local win = term.find_win_for_buf(buf)
  if win then
    if not pcall(vim.api.nvim_win_close, win, false) then
      vim.api.nvim_win_call(win, function()
        vim.cmd("enew")
      end)
    end
  else
    get_or_create_shell_term()
  end
end

local function execute_in_shell(cmd, dir)
  local code_win = vim.api.nvim_get_current_win()

  local existing = term.find_live_terminal("is_shell", true)
  if existing and platform.term_busy(existing, true) then
    term.ensure_window_for_buf(existing)
    vim.api.nvim_set_current_win(code_win)
    vim.notify("Terminal is busy; interrupt the running command first", vim.log.levels.WARN)
    return
  end

  local term_buf, term_win = get_or_create_shell_term()
  if not term_buf then
    vim.api.nvim_set_current_win(code_win)
    return
  end

  vim.api.nvim_buf_clear_namespace(term_buf, errors.ns, 0, -1)

  state._run_id = (state._run_id or 0) + 1

  local banner, start_row, full
  if config.opts.banner then
    banner = ("RUN[%d]"):format(state._run_id)

    full = table.concat({
      "cd " .. sh_quote(dir),
      "printf '\\n===== RUN[%d]: %s =====\\n' " .. state._run_id .. " \"$(date '+%H:%M:%S')\"",
      cmd,
    }, " && ")
  else
    start_row = last_content_row(term_buf)
    full = "cd " .. sh_quote(dir) .. " && " .. cmd
  end

  if config.opts.clear_run then
    -- wipe scrollback in the same line so old runs aren't scrollable; output
    -- now starts at the top, so the bannerless watcher scans from row 0
    full = term.CLEAR_SEQ .. " && " .. full
    if start_row then
      start_row = 0
    end
  end

  if banner or config.opts.park_on_error then
    errors.watch_run_output(term_buf, banner, start_row, config.opts.park_on_error)
  end
  term.term_send_command(term_buf, full)
  vim.b[term_buf].term_cwd = dir
  platform.prep_run_cache(term_buf, dir)
  vim.b[term_buf].run_banner = banner
  vim.b[term_buf].run_start_row = start_row

  term.focus_after_send(term_win, code_win, config.opts.follow_run, banner ~= nil)
end

---@class tarminal.RunContext
---@field file string
---@field stem string
---@field dir string
---@field ft string

local function is_compiler(runner)
  local exe = runner:match("%S+") or runner
  exe = exe:match("[^/]+$") or exe
  local unversioned = exe:match("^(.-)%-%d+$")
  for _, name in ipairs(config.opts.compilers) do
    if exe == name or unversioned == name then
      return true
    end
  end
  return false
end

---@return string|nil cmd, boolean run_binary, string|nil args
local function runner_spec(ft)
  local spec = config.opts.runners[ft]
  local cmd, run_binary, args = spec, nil, nil
  if type(spec) == "table" then
    cmd, run_binary, args = spec.cmd, spec.run_binary, spec.args
  end
  if run_binary == nil then
    run_binary = cmd ~= nil and is_compiler(cmd)
  end
  return cmd, run_binary, args
end

---@param ctx tarminal.RunContext
---@return string|nil
local function build_runner_command(ctx)
  local runner, run_binary, args = runner_spec(ctx.ft)
  if not runner then
    return
  end

  local suffix = (args and args ~= "") and (" " .. args) or ""
  local time = config.opts.time_runs and vim.fn.executable("time") == 1 and "time " or ""
  local file = sh_quote(ctx.file)
  if run_binary then
    local stem = ctx.stem
    if stem == vim.fn.fnamemodify(ctx.file, ":t") then
      stem = stem .. ".out"
    end
    local out = sh_quote(stem)
    return ("%s %s%s -o %s && %s./%s"):format(runner, file, suffix, out, time, out)
  end
  return time .. runner .. " " .. file .. suffix
end

---@return boolean ok
local function update_buffer(buf)
  if not config.opts.autosave then
    return true
  end
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent update")
  end)
  if not ok then
    err = tostring(err)
    vim.notify(err:match("(E%d+:[^\n]*)") or err, vim.log.levels.ERROR)
  end
  return ok
end

function M.run()
  local ctx
  local from_file = vim.bo.buftype == "" and vim.fn.expand("%:p") ~= ""
  if from_file then
    if not update_buffer(vim.api.nvim_get_current_buf()) then
      return
    end
    local current_file = vim.fn.expand("%:p")
    ctx = {
      file = current_file,
      stem = vim.fn.expand("%:t:r"),
      dir = vim.fn.fnamemodify(current_file, ":h"),
      ft = vim.bo.filetype,
    }
  else
    ctx = state._last_run
    if not ctx then
      vim.notify("Nothing to run from here", vim.log.levels.WARN)
      return
    end
    -- re-run from disk: save the source if edited
    local src = vim.fn.bufnr(ctx.file)
    if src ~= -1 and not update_buffer(src) then
      return
    end
  end

  local runner_cmd = build_runner_command(ctx)
  if not runner_cmd then
    -- don't remember an unsupported file (keep the last one that ran)
    vim.notify("No runner configured for filetype: " .. ctx.ft, vim.log.levels.WARN)
    return
  end

  if from_file then
    state._last_run = ctx
  end
  execute_in_shell(runner_cmd, ctx.dir)
end

---@param arg string|table|nil command, :Tarminal callback data, or nil
---@param verbatim boolean|nil run `arg` as given, skipping cmdline-special expansion
function M.exec(arg, verbatim)
  local input
  if type(arg) == "string" then
    input = arg
  elseif type(arg) == "table" then
    input = (arg.args or ""):gsub("^%s*%S+%s*", "")
  end

  if not input or input == "" then
    vim.ui.input({ prompt = "exec: ", default = state._last_exec_cmd, completion = "shellcmd" }, function(text)
      if text and text ~= "" then
        M.exec(text, true)
      end
    end)
    return
  end

  if vim.bo.buftype == "" and vim.fn.expand("%:p") ~= "" and not update_buffer(vim.api.nvim_get_current_buf()) then
    return
  end

  local cmd = input
  if not verbatim then
    local ok, expanded = pcall(vim.fn.expandcmd, input)
    if not ok then
      expanded = tostring(expanded)
      vim.notify(expanded:match("(E%d+:[^\n]*)") or expanded, vim.log.levels.ERROR)
      return
    end
    cmd = expanded
  end

  state._last_exec_cmd = cmd
  state._last_exec_dir = vim.fn.getcwd()
  execute_in_shell(cmd, state._last_exec_dir)
end

M.build_runner_command = build_runner_command

return M
