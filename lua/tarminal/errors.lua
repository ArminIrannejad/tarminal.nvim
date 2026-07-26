--- Error parsing, highlighting, run-output watching, and navigation.

local config = require("tarminal.config")
local platform = require("tarminal.platform")
local state = require("tarminal.state")
local term = require("tarminal.term")
local util = require("tarminal.util")

local M = {}

local uv = vim.uv or vim.loop

local SEP = util.SEP

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

local function define_error_highlight()
  local err = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  vim.api.nvim_set_hl(0, "TarminalError", { fg = err.fg or "Red", bold = true })
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  vim.api.nvim_set_hl(0, "TarminalWarning", { fg = warn.fg or "Yellow", bold = true })
end

M.ns = ns
M.parse_error_line = parse_error_line
M.logical_line_at = logical_line_at
M.watch_run_output = watch_run_output
M.define_highlight = define_error_highlight

return M
