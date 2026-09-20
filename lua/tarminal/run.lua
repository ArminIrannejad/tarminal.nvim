--- Shell terminal lifecycle and the run/exec pipeline

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
  util.emit("TarminalOpen", { buf = buf, kind = "shell" })
  term.enable_shell_integration(buf)
  return buf, win
end

-- the shell reported or was seen back at its prompt
---@param code integer|nil exit status when the prompt reports it
function M.finish(buf, code)
  local r = state._run
  if not r or r.buf ~= buf then
    return
  end
  state._run = nil
  util.emit("TarminalRunDone", {
    buf = buf,
    cmd = r.cmd,
    dir = r.dir,
    code = code,
    duration = (vim.uv.hrtime() - r.start) / 1e6,
  })
end

---@param mark string OSC 133 mark
---@param code integer|nil
function M.prompt_mark(buf, mark, code)
  local r = state._run
  if not r or r.buf ~= buf then
    return
  end
  if mark == "C" then
    r.marked = true
  elseif mark == "D" and r.marked then
    M.finish(buf, code)
  end
end

local DONE_POLL = 200
-- idle polls before a run that never looked busy counts as done
local DONE_IDLE = 2
-- a prompt that marks commands gets longer to report the status itself
local MARKED_IDLE = 10

local function watch_done(buf, id)
  local timer = vim.uv.new_timer()
  local idle, seen_busy = 0, false
  local function stop()
    timer:stop()
    timer:close()
  end
  timer:start(
    DONE_POLL,
    DONE_POLL,
    vim.schedule_wrap(function()
      if timer:is_closing() then
        return
      end
      local r = state._run
      if not r or r.id ~= id or not vim.api.nvim_buf_is_valid(buf) then
        stop()
        return
      end
      local busy = platform.term_busy(buf)
      if busy == nil then
        stop()
        return
      end
      if busy or platform.shell_has_child(buf) then
        seen_busy, idle = true, 0
        return
      end
      idle = idle + 1
      local need = r.marked and MARKED_IDLE or seen_busy and 1 or DONE_IDLE
      if idle >= need then
        stop()
        M.finish(buf)
      end
    end)
  )
end

function M.toggle()
  if not term.hide_all() and not term.show_hidden() then
    get_or_create_shell_term()
  end
end

local function execute_in_shell(cmd, dir)
  local code_win = vim.api.nvim_get_current_win()

  local existing = term.find_live_terminal("is_shell", true)
  local busy = existing and platform.term_busy(existing, true)
  if busy then
    term.ensure_window_for_buf(existing)
    vim.api.nvim_set_current_win(code_win)
    vim.notify("Terminal is busy; interrupt the running command first", vim.log.levels.WARN)
    return
  end
  -- only on a shell known idle or ^C could kill a live command
  local cancel_pending = busy == false

  local term_buf, term_win = get_or_create_shell_term()
  if not term_buf then
    vim.api.nvim_set_current_win(code_win)
    return
  end

  vim.api.nvim_buf_clear_namespace(term_buf, errors.ns, 0, -1)

  state._run_id = (state._run_id or 0) + 1

  local banner, start_row, full
  -- the banner is not unique per run so the pre-send content row keeps
  -- a stale banner from an earlier run out of the search
  start_row = last_content_row(term_buf)
  if config.opts.banner then
    banner = "RUN"

    full = table.concat({
      "cd " .. sh_quote(dir),
      "printf '\\n===== RUN: %s =====\\n' \"$(date '+%H:%M:%S')\"",
      cmd,
    }, " && ")
  else
    full = "cd " .. sh_quote(dir) .. " && " .. cmd
  end

  if config.opts.clear_run then
    full = term.CLEAR_SEQ .. " && " .. full
    start_row = 0
  end

  errors.clear_diagnostics()
  local scan = config.opts.park_on_error or config.opts.diagnostics
  if banner or scan then
    errors.watch_run_output(term_buf, banner, start_row, scan)
  end
  term.term_send_command(term_buf, full, cancel_pending)
  vim.b[term_buf].term_cwd = dir
  platform.prep_run_cache(term_buf, dir)
  vim.b[term_buf].run_banner = banner
  vim.b[term_buf].run_start_row = start_row

  if state._run then
    M.finish(state._run.buf)
  end
  state._run = { id = state._run_id, buf = term_buf, cmd = cmd, dir = dir, start = vim.uv.hrtime() }
  util.emit("TarminalRunStart", { buf = term_buf, cmd = cmd, dir = dir })
  watch_done(term_buf, state._run_id)

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
    run_binary = type(cmd) == "string" and is_compiler(cmd)
  end
  return cmd, run_binary, args
end

---@param ctx tarminal.RunContext
---@return string|nil
local function build_runner_command(ctx)
  local runner, run_binary, args = runner_spec(ctx.ft)
  if not runner or type(runner) == "function" then
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

local function applies(ft, want)
  if want == nil then
    return true
  end
  return type(want) == "table" and vim.tbl_contains(want, ft) or want == ft
end

---@param ctx tarminal.RunContext
---@return string|nil cmd, string|nil dir
local function project_command(ctx)
  for _, p in ipairs(config.opts.project_runners or {}) do
    if applies(ctx.ft, p.ft) then
      local root = vim.fs.root(ctx.file, p.marker)
      local cmd = p.cmd
      if root and type(cmd) == "function" then
        cmd = cmd(vim.deepcopy(ctx), root)
      end
      if root and cmd then
        return cmd, root
      end
    end
  end
end

local function timed(cmd)
  return config.opts.time_runs and vim.fn.executable("time") == 1 and "time " .. cmd or cmd
end

-- a project runner then a runner function then the filetype runner
---@param ctx tarminal.RunContext
---@return string|nil cmd, string|nil dir
local function resolve_run(ctx)
  local cmd, dir = project_command(ctx)
  if cmd then
    return timed(cmd), dir
  end
  local spec = config.opts.runners[ctx.ft]
  if type(spec) == "function" then
    cmd, dir = spec(vim.deepcopy(ctx))
    return cmd and timed(cmd), dir or ctx.dir
  end
  return build_runner_command(ctx), ctx.dir
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
    -- re-run from disk so save the source if edited
    local src = vim.fn.bufnr(ctx.file)
    if src ~= -1 and not update_buffer(src) then
      return
    end
  end

  local runner_cmd, dir = resolve_run(ctx)
  if not runner_cmd then
    -- don't remember an unsupported file (keep the last one that ran)
    vim.notify("No runner configured for filetype: " .. ctx.ft, vim.log.levels.WARN)
    return
  end

  if from_file then
    state._last_run = ctx
  end
  execute_in_shell(runner_cmd, dir)
end

---@param arg string|table|nil command or :Tarminal callback data or nil
---@param verbatim boolean|nil run `arg` as given with no cmdline-special expansion
function M.exec(arg, verbatim)
  local input
  if type(arg) == "string" then
    input = arg
  elseif type(arg) == "table" then
    input = (arg.args or ""):gsub("^%s*%S+%s*", "")
  end

  if not input or input == "" then
    vim.ui.input({ prompt = "exec: ", default = state._last_exec_cmd, completion = "file" }, function(text)
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
M.resolve_run = resolve_run

return M
