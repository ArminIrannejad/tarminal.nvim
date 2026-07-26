--- tarminal.nvim — terminal runner / REPL integration.

local config = require("tarminal.config")
local errors = require("tarminal.errors")
local platform = require("tarminal.platform")
local state = require("tarminal.state")
local term = require("tarminal.term")
local util = require("tarminal.util")

local M = {}

M.jump_to_error = errors.jump_to_error
M.next_error = errors.next_error
M.prev_error = errors.prev_error
M.errors_to_quickfix = errors.errors_to_quickfix

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

---@return integer
local function char_end_col(line, col)
  if col > #line then
    return #line
  end
  return col + vim.str_utf_end(line, col)
end

local function get_visual_selection(visual_mode)
  visual_mode = visual_mode or vim.fn.mode()
  if visual_mode == "v" or visual_mode == "V" or visual_mode == "\22" then
    vim.cmd("normal! \27")
  end

  local p1 = vim.fn.getpos("'<")
  local p2 = vim.fn.getpos("'>")
  local line_start, col_start = p1[2], p1[3]
  local line_end, col_end = p2[2], p2[3]

  if line_start > line_end or (line_start == line_end and col_start > col_end) then
    line_start, line_end, col_start, col_end = line_end, line_start, col_end, col_start
  end

  if visual_mode == "V" then
    return table.concat(vim.api.nvim_buf_get_lines(0, line_start - 1, line_end, false), "\n")
  end

  if visual_mode == "\22" then
    -- visual block is a screen-column rect but '< '> store byte cols; cut by screen col
    local lines = vim.api.nvim_buf_get_lines(0, line_start - 1, line_end, false)
    local c1 = vim.fn.strdisplaywidth(lines[1]:sub(1, col_start - 1)) + 1
    local c2 = vim.fn.strdisplaywidth(lines[#lines]:sub(1, col_end - 1)) + 1
    local vleft, vright = math.min(c1, c2), math.max(c1, c2)
    if vim.o.selection == "exclusive" then
      -- exclusive drops the cursor column the rightmost cell of a normal block
      vright = vright - 1
    end
    for i, line in ipairs(lines) do
      local sbyte, ebyte
      local col = 1
      local b = 1
      while b <= #line do
        local clen = vim.str_utf_end(line, b) + 1
        local last_cell = vim.fn.strdisplaywidth(line:sub(1, b + clen - 1))
        if last_cell >= vleft and col <= vright then
          sbyte = sbyte or b
          ebyte = b + clen - 1
        end
        col = last_cell + 1
        b = b + clen
      end
      lines[i] = sbyte and line:sub(sbyte, ebyte) or ""
    end
    return table.concat(lines, "\n")
  end

  local end_line = vim.api.nvim_buf_get_lines(0, line_end - 1, line_end, false)[1] or ""
  -- exclusive drops the char under '> so stop before it not at its last byte
  local end_col = vim.o.selection == "exclusive" and (col_end - 1) or char_end_col(end_line, col_end)
  local lines = vim.api.nvim_buf_get_text(0, line_start - 1, col_start - 1, line_end - 1, end_col, {})
  return table.concat(lines, "\n")
end

---@param line1 integer
---@param line2 integer
---@return string
local function get_line_range(line1, line2)
  return table.concat(vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false), "\n")
end

---@return string|nil cmd, boolean bracketed_paste, string|nil block_open, string|nil block_close
local function repl_spec(ft)
  local spec = config.opts.repls[ft]
  if type(spec) == "table" then
    return spec.cmd, spec.bracketed_paste ~= false, spec.block_open, spec.block_close
  end
  return spec, true
end

---@param ft string filetype whose REPL to reuse or start
---@return integer|nil buf, integer|nil win
local function get_or_start_repl(ft)
  local repl_cmd = repl_spec(ft)

  local buf = term.find_live_terminal("repl_ft", ft)
  if buf then
    -- REPL exited but the shell lives: relaunch it, else source hits the shell
    if repl_cmd and platform.shell_has_child(buf) == false then
      term.term_send_command(buf, repl_cmd)
      if not platform.wait_for_repl(buf) then
        vim.notify("REPL is not running: " .. repl_cmd, vim.log.levels.ERROR)
        return
      end
    end
    return buf, term.ensure_window_for_buf(buf)
  end

  if not repl_cmd then
    vim.notify("No REPL configured for filetype: " .. ft, vim.log.levels.WARN)
    return
  end

  local dir = vim.fn.expand("%:p:h")
  local win
  buf, win = term.open_shell_term("tarminal://repl:" .. ft)
  if not buf then
    return nil
  end
  term.term_cd(buf, dir)
  term.term_send_command(buf, repl_cmd)
  vim.b[buf].repl_ft = ft
  -- ensure the REPL came up before sending, else source hits the shell
  if not platform.wait_for_repl(buf) then
    vim.notify("REPL failed to start: " .. repl_cmd, vim.log.levels.ERROR)
    vim.api.nvim_buf_delete(buf, { force = true })
    return
  end
  return buf, win
end

local function send_to_repl(repl_buf, text)
  if not text:match("\n$") then
    text = text .. "\n"
  end

  local _, bracketed, block_open, block_close = repl_spec(vim.b[repl_buf].repl_ft)
  if block_open and text:match("\n.*\n$") then
    text = block_open .. "\n" .. text .. block_close .. "\n"
  elseif bracketed then
    text = "\x1b[200~" .. text .. "\x1b[201~\n"
  end
  term.term_send(repl_buf, text)
end

---@param command_opts table|nil :Tarminal command callback data
function M.send_selection(command_opts)
  local code_win = vim.api.nvim_get_current_win()
  local text
  if command_opts and command_opts.range and command_opts.range > 0 then
    text = get_line_range(command_opts.line1, command_opts.line2)
  else
    text = get_visual_selection()
  end
  local repl_buf, repl_win = get_or_start_repl(vim.bo.filetype)
  if not repl_buf then
    return
  end

  send_to_repl(repl_buf, text)
  term.focus_after_send(repl_win, code_win, config.opts.follow_repl)
end

local function line_is_marker(s)
  return config.opts.cell_marker ~= "" and vim.trim(s) == config.opts.cell_marker
end

local function get_current_cell_range()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local cur = vim.fn.line(".")

  local up = cur
  while up >= 1 and not line_is_marker(lines[up]) do
    up = up - 1
  end

  local down = line_is_marker(lines[cur]) and cur + 1 or cur
  while down <= #lines and not line_is_marker(lines[down]) do
    down = down + 1
  end

  return up + 1, down - 1
end

local function get_current_cell_text()
  local s, e = get_current_cell_range()
  if s > e then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.send_cell()
  local code_win = vim.api.nvim_get_current_win()
  local text = get_current_cell_text()
  if not text then
    vim.notify("No cell content after this marker", vim.log.levels.WARN)
    return
  end
  local repl_buf, repl_win = get_or_start_repl(vim.bo.filetype)
  if not repl_buf then
    return
  end

  send_to_repl(repl_buf, text)
  term.focus_after_send(repl_win, code_win, config.opts.follow_repl)
end

---@param opts tarminal.Config|nil merged over the defaults
function M.setup(opts)
  config.setup(opts)
  local group = vim.api.nvim_create_augroup("tarminal-highlight", { clear = true })

  errors.define_highlight()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = errors.define_highlight,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      platform.clear_cache(ev.buf)
    end,
  })
  pcall(vim.api.nvim_create_autocmd, "TermRequest", {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].filetype ~= "tarminal" then
        return
      end
      local seq = type(ev.data) == "table" and ev.data.sequence or ev.data
      if type(seq) ~= "string" then
        return
      end
      local cwd = platform.osc7_cwd(seq)
      if cwd and cwd ~= "" then
        vim.b[ev.buf].term_cwd = cwd
        vim.b[ev.buf].osc7_active = true
      end
    end,
  })
end

-- compat: keep config and the historical M._* fields readable on the facade
setmetatable(M, {
  __index = function(_, k)
    if k == "config" then
      return config.opts
    end
    return state[k]
  end,
})

return M
