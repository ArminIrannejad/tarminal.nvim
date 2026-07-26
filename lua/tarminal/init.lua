--- tarminal.nvim — terminal runner / REPL integration.

local config = require("tarminal.config")
local platform = require("tarminal.platform")
local state = require("tarminal.state")
local term = require("tarminal.term")
local util = require("tarminal.util")

local M = {}

local uv = vim.uv or vim.loop

local SEP = util.SEP
local sh_quote = util.sh_quote

---@return string|nil
local function resolve_file(path, term_buf)
  if path:sub(1, 1) == "~" then
    path = vim.fn.expand(path)
  end
  local candidates
  local is_abs = path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
  if is_abs then
    candidates = { path }
  else
    candidates = {}
    local cwd = platform.term_cwd(term_buf)
    if cwd then
      candidates[#candidates + 1] = cwd .. SEP .. path
    end
    candidates[#candidates + 1] = vim.fn.getcwd() .. SEP .. path
  end
  for _, p in ipairs(candidates) do
    if vim.fn.filereadable(p) == 1 then
      return p
    end
  end
end

---@return string|nil path, integer|nil offset byte offset of the path
local function resolve_file_suffix(candidate, term_buf)
  local trimmed = vim.trim(candidate)
  local trim_offset = candidate:find(trimmed, 1, true) - 1
  local start = 1

  while true do
    local suffix = trimmed:sub(start)
    local path = resolve_file(suffix, term_buf)
    if path then
      return path, trim_offset + start - 1
    end
    if suffix:match("^[%(%[<'\"]") then
      path = resolve_file(suffix:sub(2), term_buf)
      if path then
        return path, trim_offset + start
      end
    end

    local _, ws_end = trimmed:find("%s+", start)
    local bracket = trimmed:find("[%(%[<]", start)
    local next_start = ws_end and ws_end + 1
    if bracket and (not next_start or bracket + 1 < next_start) then
      next_start = bracket + 1
    end
    if not next_start then
      return
    end
    start = next_start
  end
end

local SEVERITY_RANK = { note = 0, info = 0, warning = 1, warn = 1, error = 2 }
local function severity_rank(word)
  return word and SEVERITY_RANK[word:lower()] or 2
end

---@return string|nil file, integer|nil lnum, integer|nil col,
---        integer|nil span_s, integer|nil span_e, integer|nil sev
local function match_patterns(line, term_buf)
  local best
  for _, pat in ipairs(config.opts.error_patterns) do
    local init = 1
    while true do
      -- caps[1..2] = match bounds; capture N = caps[2+N]
      local caps = { line:find(pat.pattern, init) }
      local s, e = caps[1], caps[2]
      if not s then
        break
      end
      local raw = caps[2 + pat.file]
      local path = resolve_file(raw, term_buf)
      if not path and pat.resolve == false then
        path = raw:sub(1, 1) == "~" and vim.fn.expand(raw) or raw
      end
      if path then
        if not best or s < best.s then
          local word = type(pat.type) == "number" and caps[2 + pat.type] or pat.type
          best = {
            file = path,
            lnum = pat.lnum and tonumber(caps[2 + pat.lnum]),
            col = pat.col and tonumber(caps[2 + pat.col]),
            s = s,
            e = e,
            sev = severity_rank(word),
          }
        end
        break
      end
      init = e + 1
    end
  end
  if best then
    return best.file, best.lnum, best.col, best.s, best.e, best.sev
  end
end

---@return string|nil file, integer|nil lnum, integer|nil col
---@return integer|nil span_s, integer|nil span_e, integer|nil sev
local function parse_error_line(line, term_buf)
  local file, lnum, col, span_s, span_e, sev = match_patterns(line, term_buf)
  if file then
    return file, lnum, col, span_s, span_e, sev
  end

  local init = 1
  while true do
    local s, e, f, l, c = line:find("([%a]?:?[^:'\"]+):(%d+):?(%d*)", init)
    if not s then
      return
    end
    local path, offset = resolve_file_suffix(f, term_buf)
    if path then
      return path, tonumber(l), tonumber(c), s + offset, e, 2
    end
    init = e + 1
  end
end

---@return integer
local function pty_width(term_buf)
  local win = term.find_win_for_buf(term_buf)
  return win and vim.api.nvim_win_get_width(win) or vim.o.columns
end

---@return string logical, integer first_row, integer last_row
local function logical_line_at(lines, row, width)
  local first, last = row, row
  while first > 1 and vim.fn.strdisplaywidth(lines[first - 1]) == width do
    first = first - 1
  end
  while last < #lines and vim.fn.strdisplaywidth(lines[last]) == width do
    last = last + 1
  end
  return table.concat(lines, "", first, last), first, last
end

---@return integer|nil win
local function pick_code_win()
  local wins = {}
  if state._last_code_win then
    wins[#wins + 1] = state._last_code_win
  end
  wins[#wins + 1] = vim.fn.win_getid(vim.fn.winnr("#"))
  vim.list_extend(wins, vim.api.nvim_tabpage_list_wins(0))
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(wins) do
    if
      win ~= 0
      and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_tabpage(win) == tab
      and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
    then
      return win
    end
  end
end

-- only tarminal's own terminals (ft "tarminal"); never a plain :terminal
---@return integer|nil term_buf
local function current_term_buf()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "terminal" or vim.bo[buf].filetype ~= "tarminal" then
    vim.notify("Not in a tarminal terminal", vim.log.levels.WARN)
    return nil
  end
  return buf
end

function M.jump_to_error()
  local term_buf = current_term_buf()
  if not term_buf then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = logical_line_at(lines, row, pty_width(term_buf))
  local file, lnum, col = parse_error_line(line, term_buf)
  if not file then
    vim.notify("No file location on this line", vim.log.levels.WARN)
    return
  end

  local win = pick_code_win()
  if not win then
    vim.cmd("aboveleft split")
    win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(win)

  local buf = vim.fn.bufadd(file)
  vim.bo[buf].buflisted = true
  local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  -- no line number -> line 1; linkers emit line 0 — clamp both ends
  lnum = math.min(math.max(lnum or 1, 1), vim.api.nvim_buf_line_count(buf))
  vim.api.nvim_win_set_cursor(win, { lnum, math.max((col or 1) - 1, 0) })
  vim.cmd("normal! zz")
end

local WATCH_INTERVAL = 200
local WATCH_TIMEOUT = 30000

local ns = vim.api.nvim_create_namespace("tarminal.errors")

local function severity_hl(sev)
  return (sev or 2) >= 2 and "TarminalError" or "TarminalWarning"
end

local function highlight_span(term_buf, lines, first_row, last_row, span_s, span_e, hl_group)
  local off = 0
  for row = first_row, last_row do
    local len = #lines[row]
    local cs = math.max(span_s - off, 1)
    local ce = math.min(span_e - off, len)
    if cs <= ce then
      vim.api.nvim_buf_set_extmark(term_buf, ns, row - 1, cs - 1, {
        end_col = ce,
        hl_group = hl_group or "TarminalError",
        strict = false,
      })
    end
    off = off + len
  end
end

-- row of the last RUN banner (^===== guards against output quoting it)
---@return integer|nil row
local function find_banner_row(lines, banner_token)
  for i = #lines, 1, -1 do
    if lines[i]:match("^=====") and lines[i]:find(banner_token, 1, true) then
      return i
    end
  end
end

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

---@param banner_token string|nil marker printed before the output
---@param start_row integer|nil row output starts after, when bannerless
---@param scan_errors boolean
local function watch_run_output(term_buf, banner_token, start_row, scan_errors)
  if state._watch_timer then
    state._watch_timer:stop()
    state._watch_timer:close()
    state._watch_timer = nil
  end

  local elapsed = 0
  local pinned = banner_token == nil
  local pin_row = nil
  local parked = false
  local seen = false
  local last_tick = vim.api.nvim_buf_get_changedtick(term_buf)
  local timer = uv.new_timer()
  state._watch_timer = timer

  local function stop()
    timer:stop()
    timer:close()
    if state._watch_timer == timer then
      state._watch_timer = nil
    end
  end

  local function flush_pin()
    if not pin_row then
      return
    end
    local w = term.find_win_for_buf(term_buf)
    if w then
      vim.api.nvim_win_call(w, function()
        local view = vim.fn.winsaveview()
        view.topline = pin_row
        vim.fn.winrestview(view)
      end)
    end
    pin_row = nil
  end

  timer:start(
    WATCH_INTERVAL,
    WATCH_INTERVAL,
    vim.schedule_wrap(function()
      if timer:is_closing() then
        return
      end
      if not vim.api.nvim_buf_is_valid(term_buf) then
        stop()
        return
      end

      local tick = vim.api.nvim_buf_get_changedtick(term_buf)
      if tick == last_tick then
        elapsed = elapsed + WATCH_INTERVAL
        local busy = platform.term_busy(term_buf)
        if (seen and busy == false) or (busy ~= true and elapsed > WATCH_TIMEOUT) then
          flush_pin()
          stop()
        end
        return
      end
      last_tick = tick
      elapsed = 0

      local lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
      local banner_row = start_row
      if banner_token then
        banner_row = find_banner_row(lines, banner_token)
        if not banner_row then
          return
        end
      end
      seen = true

      local win = term.find_win_for_buf(term_buf)

      local typing = win == vim.api.nvim_get_current_win() and vim.api.nvim_get_mode().mode:sub(1, 1) == "t"

      if not pinned then
        pinned = true
        if win and typing then
          pin_row = banner_row
        elseif win then
          vim.api.nvim_win_call(win, function()
            vim.fn.winrestview({ topline = banner_row, lnum = banner_row, col = 0 })
          end)
        end
      end

      if not scan_errors then
        if not pin_row then
          stop()
        end
        return
      end

      vim.api.nvim_buf_clear_namespace(term_buf, ns, banner_row, -1)
      local width = pty_width(term_buf)
      local i = banner_row + 1
      while i <= #lines do
        local logical, first, last = logical_line_at(lines, i, width)
        local file, _, _, span_s, span_e, sev = parse_error_line(logical, term_buf)
        if file then
          highlight_span(term_buf, lines, first, last, span_s, span_e, severity_hl(sev))
          if not parked and sev >= config.opts.error_threshold then
            parked = true
            if win and not typing then
              vim.api.nvim_win_set_cursor(win, { math.max(first, banner_row + 1), 0 })
            end
          end
        end
        i = last + 1
      end
    end)
  )
end

---@param dir integer 1 (down) or -1 (up)
local function goto_error(dir)
  local term_buf = current_term_buf()
  if not term_buf then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
  local width = pty_width(term_buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]

  local _, cur_first, cur_last = logical_line_at(lines, row, width)
  local i = dir > 0 and cur_last + 1 or cur_first - 1
  while i >= 1 and i <= #lines do
    local logical, first, last = logical_line_at(lines, i, width)
    local file, _, _, _, _, sev = parse_error_line(logical, term_buf)
    if file and sev >= config.opts.error_threshold then
      vim.api.nvim_win_set_cursor(0, { first, 0 })
      return
    end
    i = dir > 0 and last + 1 or first - 1
  end
  vim.notify("No more error locations", vim.log.levels.WARN)
end

function M.next_error()
  goto_error(1)
end

function M.prev_error()
  goto_error(-1)
end

function M.errors_to_quickfix()
  local term_buf = current_term_buf()
  if not term_buf then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
  local width = pty_width(term_buf)

  local start_row = 1
  local banner = vim.b[term_buf].run_banner
  if banner then
    local banner_row = find_banner_row(lines, banner)
    if banner_row then
      start_row = banner_row + 1
    end
  elseif vim.b[term_buf].run_start_row then
    start_row = vim.b[term_buf].run_start_row + 1
  end

  local items = {}
  local i = start_row
  while i <= #lines do
    local logical, _, last = logical_line_at(lines, i, width)
    local file, lnum, col, _, _, sev = parse_error_line(logical, term_buf)
    if file and sev >= config.opts.error_threshold then
      items[#items + 1] = {
        filename = file,
        lnum = lnum or 1,
        col = col or 1,
        text = vim.trim(logical),
        type = ({ [0] = "I", [1] = "W", [2] = "E" })[sev] or "E",
      }
    end
    i = last + 1
  end

  if #items == 0 then
    vim.notify("No error locations in terminal output", vim.log.levels.WARN)
    return
  end

  vim.fn.setqflist({}, " ", { title = "tarminal errors", items = items })
  local qf = config.opts.quickfix
  if qf.close_terminal then
    local win = term.find_win_for_buf(term_buf)
    if win and not pcall(vim.api.nvim_win_close, win, false) then
      vim.api.nvim_win_call(win, function()
        vim.cmd("enew")
      end)
    end
  end
  if qf.open then
    vim.cmd("botright copen")
  else
    vim.notify(("%d error location(s) collected into quickfix"):format(#items), vim.log.levels.INFO)
  end
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

  vim.api.nvim_buf_clear_namespace(term_buf, ns, 0, -1)

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
    watch_run_output(term_buf, banner, start_row, config.opts.park_on_error)
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

local function define_error_highlight()
  local err = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  vim.api.nvim_set_hl(0, "TarminalError", { fg = err.fg or "Red", bold = true })
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  vim.api.nvim_set_hl(0, "TarminalWarning", { fg = warn.fg or "Yellow", bold = true })
end

---@param opts tarminal.Config|nil merged over the defaults
function M.setup(opts)
  config.setup(opts)
  local group = vim.api.nvim_create_augroup("tarminal-highlight", { clear = true })

  define_error_highlight()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_error_highlight,
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
