--- Error parsing highlighting run output watching and navigation

local config = require("tarminal.config")
local platform = require("tarminal.platform")
local state = require("tarminal.state")
local term = require("tarminal.term")
local util = require("tarminal.util")

local M = {}

local uv = vim.uv

-- a run's output is rescanned on every tick so the lookups it repeats are
-- kept for the run: each line's parse and each path's resolution
---@class tarminal.ScanCache
---@field lines table<string, table> line text to its parse results
---@field next_lines table<string, table> lines still visible in the current scan
---@field paths table<string, string|false> raw path to the file it resolved to
---@field path_count integer

---@return tarminal.ScanCache
local function new_cache()
  return { lines = {}, next_lines = {}, paths = {}, path_count = 0 }
end

local function clean_root(path)
  path = path and (uv.fs_realpath(path) or path)
  return path and path:gsub("/+$", "")
end

local function workspace_root(dir)
  if uv.fs_stat(dir .. "/.git") or uv.fs_stat(dir .. "/.hg") or uv.fs_stat(dir .. "/.svn") then
    return true
  end
  if vim.fn.filereadable(dir .. "/go.work") == 1 then
    return true
  end
  local cargo = dir .. "/Cargo.toml"
  if vim.fn.filereadable(cargo) == 1 then
    for _, line in ipairs(vim.fn.readfile(cargo, "", 200)) do
      if line:match("^%s*%[workspace%]%s*$") then
        return true
      end
    end
  end
  return false
end

-- a tool can print paths relative to a root above where it ran
-- like cargo in a workspace member: crates/foo/src/main.rs
-- only paths with a directory in them are tried there, bounded by a project
-- root or $HOME so system trees cannot be mistaken for the workspace
local function add_ancestors(candidates, base, path)
  if not path:find("/", 1, true) or path:match("^%.%.?/") then
    return
  end
  base = clean_root(base)
  local home = clean_root(uv.os_homedir())
  if base == home or workspace_root(base) then
    return
  end
  local inside_home = home and vim.startswith(base, home .. "/")
  local first = #candidates + 1
  for parent in vim.fs.parents(base) do
    if parent == "/" or parent == home then
      break
    end
    candidates[#candidates + 1] = parent .. "/" .. path
    if workspace_root(parent) then
      return
    end
  end
  -- outside $HOME, no project marker means there is no safe workspace bound
  if not inside_home then
    for i = #candidates, first, -1 do
      candidates[i] = nil
    end
  end
end

---@param cache tarminal.ScanCache|nil
---@param dir string|nil directory make or ninja said it entered
---@return string|nil
local function resolve_file(path, term_buf, cache, dir)
  local key = dir and dir .. "\0" .. path or path
  local hit = cache and cache.paths[key]
  if hit ~= nil then
    return hit or nil
  end
  if path:sub(1, 1) == "~" then
    path = vim.fn.expand(path)
  end
  local candidates
  if path:sub(1, 1) == "/" then
    candidates = { path }
  else
    candidates = {}
    if dir then
      candidates[#candidates + 1] = dir .. "/" .. path
    end
    local cwd = platform.term_cwd(term_buf)
    if cwd then
      candidates[#candidates + 1] = cwd .. "/" .. path
    end
    candidates[#candidates + 1] = vim.fn.getcwd() .. "/" .. path
    add_ancestors(candidates, cwd or vim.fn.getcwd(), path)
  end
  local found
  for _, p in ipairs(candidates) do
    if vim.fn.filereadable(p) == 1 then
      found = p
      break
    end
  end
  if cache then
    cache.paths[key] = found or false
    cache.path_count = cache.path_count + 1
  end
  return found
end

---@return string|nil path, integer|nil offset byte offset of the path
local function resolve_file_suffix(candidate, term_buf, cache, dir)
  local trimmed = vim.trim(candidate)
  local trim_offset = candidate:find(trimmed, 1, true) - 1
  local start = 1

  while true do
    local suffix = trimmed:sub(start)
    local path = resolve_file(suffix, term_buf, cache, dir)
    if path then
      return path, trim_offset + start - 1
    end
    if suffix:match("^[%(%[<'\"]") then
      path = resolve_file(suffix:sub(2), term_buf, cache, dir)
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

local SEVERITY_RANK = { note = 0, info = 0, hint = 0, remark = 0, warning = 1, warn = 1, error = 2, fatal = 2 }
local function severity_rank(word)
  if not word then
    return 2
  end
  word = word:lower()
  -- python warning classes like DeprecationWarning
  if word:sub(-7) == "warning" then
    return 1
  end
  return SEVERITY_RANK[word] or 2
end

---@return string|nil file, integer|nil lnum, integer|nil col,
---        integer|nil span_s, integer|nil span_e, integer|nil sev
local function match_patterns(line, term_buf, cache, dir)
  local best
  for _, pat in ipairs(config.opts.error_patterns) do
    if not pat.contains or line:find(pat.contains, 1, true) then
      local init = 1
      while true do
        -- caps[1..2] is the match bounds and caps[2+N] is capture N
        local caps = { line:find(pat.pattern, init) }
        local s, e = caps[1], caps[2]
        if not s then
          break
        end
        local raw = caps[2 + pat.file]
        local path = resolve_file(raw, term_buf, cache, dir)
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
    -- no later pattern can start farther left than the first byte
    if best and best.s == 1 then
      break
    end
  end
  if best then
    return best.file, best.lnum, best.col, best.s, best.e, best.sev
  end
end

---@return string|nil file, integer|nil lnum, integer|nil col
---@return integer|nil span_s, integer|nil span_e, integer|nil sev
---@param cache tarminal.ScanCache|nil
---@param dir string|nil directory relative paths are tried against first
local function parse_error_line(line, term_buf, cache, dir)
  local file, lnum, col, span_s, span_e, sev = match_patterns(line, term_buf, cache, dir)
  if file then
    return file, lnum, col, span_s, span_e, sev
  end

  local init = 1
  while true do
    local s, e, f, l, c = line:find("([^:'\"]+):(%d+):?(%d*)", init)
    if not s then
      return
    end
    local path, offset = resolve_file_suffix(f, term_buf, cache, dir)
    if path then
      local word = line:match("^:?%s*(%a+)", e + 1)
      return path, tonumber(l), tonumber(c), s + offset, e, severity_rank(word)
    end
    init = e + 1
  end
end

-- a hidden terminal keeps the pty size it last had
---@type table<integer, integer>
local last_pty_width = {}

-- neovim sizes the pty to the widest window showing the terminal in any tab
-- less its sign number and fold columns
---@return integer
local function pty_width(term_buf)
  local layout, width = {}, nil
  for _, win in ipairs(vim.fn.win_findbuf(term_buf)) do
    local info = vim.fn.getwininfo(win)[1]
    layout[#layout + 1] = win .. ":" .. info.width
    local inner = info.width - info.textoff
    -- a window no wider than its columns has no text to size the pty by
    if inner > 0 then
      width = math.max(width or 0, inner)
    end
  end
  table.sort(layout)
  local signature = table.concat(layout, ",")
  local saved_layout = vim.b[term_buf].terminal_pty_layout
  local saved_width = vim.b[term_buf].terminal_pty_width
  if signature ~= "" and signature == saved_layout and saved_width then
    -- termopen can hide inherited columns after sizing the pty; unchanged
    -- outer widths mean the pty still has the width captured before that
    width = saved_width
  elseif width then
    vim.b[term_buf].terminal_pty_layout = signature
    vim.b[term_buf].terminal_pty_width = width
  end
  if width then
    last_pty_width[term_buf] = width
  end
  return width or saved_width or last_pty_width[term_buf] or vim.o.columns
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

---@param cache tarminal.ScanCache|nil
local function parse_cached(line, term_buf, cache, dir)
  if not cache then
    return parse_error_line(line, term_buf, nil, dir)
  end
  local key = dir and dir .. "\0" .. line or line
  local hit = cache.next_lines[key] or cache.lines[key]
  if not hit then
    hit = { parse_error_line(line, term_buf, cache, dir) }
  end
  cache.next_lines[key] = hit
  return hit[1], hit[2], hit[3], hit[4], hit[5], hit[6]
end

-- the directory in a make or ninja "Entering directory 'dir'" line
-- quoted `dir' 'dir' or ‘dir’ depending on the version and locale
---@param word string "Entering" or "Leaving"
---@return string|nil
local function announced_dir(line, word)
  local dir = line:match("^%s*%S+: " .. word .. " directory (.-)%s*$")
  if not dir then
    return nil
  end
  dir = dir:gsub("^[`'\"]", ""):gsub("^\226\128\152", "")
  return (dir:gsub("['\"]$", ""):gsub("\226\128\153$", ""))
end

local function is_run_banner(line)
  return line:match("^===== RUN: %d%d:%d%d:%d%d =====$") ~= nil
end

-- paths printed after make -C or ninja -C are relative to the directory it
-- entered until make leaves it again
-- a RUN banner starts over so a make cut short can't leak into the next run
---@return table<integer, string>|nil dirs row to its directory or nil when none
local function dir_map(lines, from, term_buf, width)
  local dirs, stack, any = {}, {}, false
  local row = from or 1
  width = width or pty_width(term_buf)
  while row <= #lines do
    local line, first, last = logical_line_at(lines, row, width)
    if line:find(" directory ", 1, true) then
      local entered = announced_dir(line, "Entering")
      if entered then
        if entered:sub(1, 1) ~= "/" then
          entered = (stack[#stack] or platform.term_cwd(term_buf) or vim.fn.getcwd()) .. "/" .. entered
        end
        stack[#stack + 1] = entered
        any = true
      else
        local left = announced_dir(line, "Leaving")
        if left then
          local match
          for i = #stack, 1, -1 do
            if stack[i] == left or (left:sub(1, 1) ~= "/" and stack[i]:sub(-#left - 1) == "/" .. left) then
              match = i
              break
            end
          end
          if match then
            for i = #stack, match, -1 do
              stack[i] = nil
            end
          else
            stack[#stack] = nil
          end
        end
      end
    elseif is_run_banner(line) then
      stack = {}
    end
    for r = math.max(first, from or 1), last do
      dirs[r] = stack[#stack]
    end
    row = last + 1
  end
  return any and dirs or nil
end

local function dir_scan_start(term_buf, row)
  local start = vim.b[term_buf].run_start_row
  return start and start <= row and start + 1 or 1
end

---@param cache tarminal.ScanCache|nil
---@param dirs table<integer, string>|nil from dir_map
---@return integer first, integer last, string|nil file, integer|nil lnum,
---        integer|nil col, integer|nil span_s, integer|nil span_e, integer|nil sev
local function scan_logical_at(lines, row, width, term_buf, min_row, max_row, cache, dirs)
  local logical, first, last = logical_line_at(lines, row, width)
  local file, lnum, col, s, e, sev = parse_cached(logical, term_buf, cache, dirs and dirs[first])
  if not file and first ~= last then
    for r = math.max(first, min_row or first), math.min(last, max_row or last) do
      file, lnum, col, s, e, sev = parse_cached(lines[r], term_buf, cache, dirs and dirs[r])
      if file then
        return r, r, file, lnum, col, s, e, sev
      end
    end
  end
  return first, last, file, lnum, col, s, e, sev
end

-- panels that stay panels because taking one over destroys what it shows
local KEEP = { terminal = true, quickfix = true, help = true, prompt = true }

-- an oil/dirvish-style window is still a file window
-- reuse it rather than splitting a third window in
local function reusable(win, tab)
  return win ~= 0
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_tabpage(win) == tab
    and vim.api.nvim_win_get_config(win).relative == ""
    and not KEEP[vim.bo[vim.api.nvim_win_get_buf(win)].buftype]
end

-- a window already showing the file so the layout stays as it is
-- other tabs only count when 'switchbuf' has usetab like :sbuffer
---@param buf integer
---@return integer|nil win
local function win_showing(buf)
  local tabs = { vim.api.nvim_get_current_tabpage() }
  if vim.tbl_contains(vim.opt.switchbuf:get(), "usetab") then
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if tab ~= tabs[1] then
        tabs[#tabs + 1] = tab
      end
    end
  end
  for _, tab in ipairs(tabs) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_win_get_config(win).relative == "" then
        return win
      end
    end
  end
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
  -- a real file window first then any reusable one
  for _, win in ipairs(wins) do
    if reusable(win, tab) and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
      return win
    end
  end
  for _, win in ipairs(wins) do
    if reusable(win, tab) then
      return win
    end
  end
end

-- tarminal's own terminals unless any_terminal opts others in
---@return integer|nil term_buf
local function current_term_buf()
  local buf = vim.api.nvim_get_current_buf()
  local ours = util.owns(buf) or config.opts.any_terminal
  if vim.bo[buf].buftype ~= "terminal" or not ours then
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
  local floating = vim.api.nvim_win_get_config(0).relative ~= ""
  local lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local width = pty_width(term_buf)
  local dirs = dir_map(lines, dir_scan_start(term_buf, row), term_buf, width)
  local _, _, file, lnum, col = scan_logical_at(lines, row, width, term_buf, nil, nil, nil, dirs)
  if not file then
    vim.notify("No file location on this line", vim.log.levels.WARN)
    return
  end

  local buf = vim.fn.bufadd(file)
  vim.bo[buf].buflisted = true
  local close = config.opts.close_on_jump or floating
  local win = win_showing(buf)
  if win and close and vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
    -- the terminal is only found in its own tab so hide it before leaving
    term.close_window_for_buf(term_buf)
    close = false
  end
  win = win or pick_code_win()
  if not win then
    vim.cmd("aboveleft split")
    win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(win)
  -- setting the cursor leaves no jumplist entry so <C-o> would skip this spot
  vim.cmd("normal! m'")

  -- a winfixbuf window already showing the file must not split it in two
  local ok, err = true, nil
  if vim.api.nvim_win_get_buf(win) ~= buf then
    ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
  end
  if not ok then
    -- a winfixbuf window refuses a new buffer so split off that one
    vim.cmd("aboveleft split")
    win = vim.api.nvim_get_current_win()
    ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
  end
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  -- clamp both ends for a missing line number and the 0 linkers emit
  lnum = math.min(math.max(lnum or 1, 1), vim.api.nvim_buf_line_count(buf))
  vim.api.nvim_win_set_cursor(win, { lnum, math.max((col or 1) - 1, 0) })
  -- a closed fold would hide the line the jump is for
  vim.cmd("normal! zvzz")

  if close then
    term.close_window_for_buf(term_buf)
  end
end

local WATCH_INTERVAL = 200
local WATCH_TIMEOUT = 30000
-- let the output settle before calling a run done
local QUIET_GRACE = 1000

local ns = vim.api.nvim_create_namespace("tarminal.errors")
local diag_ns = vim.api.nvim_create_namespace("tarminal.diagnostics")

local DIAG_SEVERITY =
  { [0] = vim.diagnostic.severity.INFO, vim.diagnostic.severity.WARN, vim.diagnostic.severity.ERROR }

local published
local pending = {}

local function path_key(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function clear_diagnostics()
  published, pending = nil, {}
  vim.diagnostic.reset(diag_ns)
end

local function diag_message(lines, first, last, span_e, term_buf, min_row, cache, dirs)
  local logical = table.concat(lines, "", first, last)
  local rest = vim.trim((logical:sub(span_e + 1):gsub("^[%s:,]+", "")))
  if vim.trim(logical):match('^File "') then
    for i = last + 1, #lines do
      if lines[i]:match("^%S") then
        return vim.trim(lines[i]) .. (rest ~= "" and " (" .. rest .. ")" or "")
      end
    end
  end
  if rest ~= "" then
    return rest
  end
  local above = first - 1 > min_row and vim.trim(lines[first - 1]) or ""
  if above ~= "" and not parse_cached(above, term_buf, cache, dirs and dirs[first - 1]) then
    return above
  end
  return vim.trim(logical)
end

---@param by_file table<string, vim.Diagnostic[]>
local function publish_diagnostics(by_file)
  if vim.deep_equal(by_file, published) then
    return
  end
  clear_diagnostics()
  published = vim.deepcopy(by_file)
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    bufs[path_key(vim.api.nvim_buf_get_name(buf))] = buf
  end
  for file, items in pairs(by_file) do
    local key = path_key(file)
    if bufs[key] then
      vim.diagnostic.set(diag_ns, bufs[key], items)
    else
      pending[key] = items
    end
  end
end

local function flush_diagnostics(buf)
  local key = path_key(vim.api.nvim_buf_get_name(buf))
  if pending[key] then
    vim.diagnostic.set(diag_ns, buf, pending[key])
    pending[key] = nil
  end
end

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

-- row of the last exact RUN banner below `min_row`
---@return integer|nil row
local function find_banner_row(lines, banner_token, min_row)
  for i = #lines, (min_row or 0) + 1, -1 do
    if is_run_banner(lines[i]) and lines[i]:find(banner_token, 1, true) then
      return i
    end
  end
end

-- rows the dimmed command line takes right after the run head
local function echo_rows(term_buf, lines, row, width)
  local echo = vim.b[term_buf].run_echo
  local line = lines[row + 1]
  if not echo or not line or line == "" or echo:sub(1, #line) ~= line then
    return 0
  end
  return math.max(math.ceil(vim.fn.strdisplaywidth(echo) / width), 1)
end

-- the cursor rides the run's last line until it parks or you move it
local function follow_tail(term_buf)
  if not vim.api.nvim_buf_is_valid(term_buf) then
    return
  end
  local anchor = vim.b[term_buf].run_anchor
  local win = term.find_win_for_buf(term_buf)
  if not anchor or not win or vim.api.nvim_win_get_cursor(win)[1] ~= anchor then
    return
  end
  if win == vim.api.nvim_get_current_win() and vim.api.nvim_get_mode().mode:sub(1, 1) == "t" then
    return
  end
  local row = math.max(term.last_content_row(term_buf), anchor)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  vim.b[term_buf].run_anchor = row
end

---@param banner_token string|nil marker printed before the output
---@param start_row integer|nil row the run's output starts after
---@param scan_errors boolean
local function watch_run_output(term_buf, banner_token, start_row, scan_errors)
  if state._watch_timer then
    state._watch_timer:stop()
    state._watch_timer:close()
    state._watch_timer = nil
  end

  local elapsed = 0
  local cache = new_cache()
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
        -- a live child means output may still be coming
        local settled = busy == false and elapsed >= QUIET_GRACE and platform.shell_has_child(term_buf) ~= true
        if (seen and settled) or (busy ~= true and elapsed > WATCH_TIMEOUT) then
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
        banner_row = find_banner_row(lines, banner_token, start_row)
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
          local lnum = math.max(term.last_content_row(term_buf), banner_row)
          vim.api.nvim_win_call(win, function()
            vim.fn.winrestview({ topline = banner_row, lnum = lnum, col = 0 })
          end)
          vim.b[term_buf].run_anchor = lnum
        end
      end
      follow_tail(term_buf)

      if not scan_errors then
        return
      end

      local park = config.opts.park_on_error
      local diags = config.opts.diagnostics and {}
      vim.api.nvim_buf_clear_namespace(term_buf, ns, banner_row, -1)
      local width = pty_width(term_buf)
      local head = banner_row + echo_rows(term_buf, lines, banner_row, width)
      local dirs = dir_map(lines, head + 1, term_buf, width)
      cache.next_lines = {}
      local i = head + 1
      while i <= #lines do
        local first, last, file, lnum, col, span_s, span_e, sev =
          scan_logical_at(lines, i, width, term_buf, i, nil, cache, dirs)
        if file and diags and sev >= config.opts.error_threshold then
          diags[file] = diags[file] or {}
          table.insert(diags[file], {
            lnum = math.max((lnum or 1) - 1, 0),
            col = math.max((col or 1) - 1, 0),
            severity = DIAG_SEVERITY[sev],
            message = diag_message(lines, first, last, span_e, term_buf, head, cache, dirs),
            source = "tarminal",
          })
        end
        if file and park then
          highlight_span(term_buf, lines, first, last, span_s, span_e, severity_hl(sev))
          if not parked and sev >= config.opts.error_threshold then
            parked = true
            if win and not typing then
              vim.api.nvim_win_set_cursor(win, { math.max(first, head + 1), 0 })
              vim.b[term_buf].run_anchor = nil
            end
          end
        end
        i = last + 1
      end
      cache.lines, cache.next_lines = cache.next_lines, {}
      if cache.path_count > math.max(#lines * 4, 1000) then
        cache.paths, cache.path_count = {}, 0
      end
      if diags then
        publish_diagnostics(diags)
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
  local cache, dirs = new_cache(), dir_map(lines, dir_scan_start(term_buf, row), term_buf, width)
  local i = dir > 0 and cur_last + 1 or cur_first - 1
  while i >= 1 and i <= #lines do
    local first, last, file, _, _, _, _, sev =
      scan_logical_at(lines, i, width, term_buf, dir > 0 and i or nil, dir < 0 and i or nil, cache, dirs)
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

local QF_TITLE = "tarminal errors"

local function qf_is_ours()
  return vim.fn.getqflist({ title = 0 }).title == QF_TITLE
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
  local run_start = vim.b[term_buf].run_start_row
  if banner then
    local banner_row = find_banner_row(lines, banner, run_start)
    if banner_row then
      start_row = banner_row + 1
    end
  elseif run_start then
    start_row = run_start + 1
  end
  start_row = start_row + echo_rows(term_buf, lines, start_row - 1, width)

  local items = {}
  local cache, dirs = new_cache(), dir_map(lines, start_row, term_buf, width)
  local i = start_row
  while i <= #lines do
    -- scanned so a width-filling line can't swallow the error under it
    local first, last, file, lnum, col, _, _, sev = scan_logical_at(lines, i, width, term_buf, i, nil, cache, dirs)
    if file and sev >= config.opts.error_threshold then
      items[#items + 1] = {
        filename = file,
        lnum = lnum or 1,
        col = col or 1,
        text = vim.trim(table.concat(lines, "", first, last)),
        type = ({ [0] = "I", [1] = "W", [2] = "E" })[sev] or "E",
      }
    end
    i = last + 1
  end

  if #items == 0 then
    if qf_is_ours() then
      vim.fn.setqflist({}, "r", { title = QF_TITLE, items = {} })
    end
    vim.notify("No error locations in terminal output", vim.log.levels.WARN)
    return
  end

  vim.fn.setqflist({}, qf_is_ours() and "r" or " ", { title = QF_TITLE, items = items })
  local qf = config.opts.quickfix
  if qf.close_terminal then
    term.close_window_for_buf(term_buf)
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
M.diag_ns = diag_ns
M.clear_diagnostics = clear_diagnostics
M.flush_diagnostics = flush_diagnostics
M.parse_error_line = parse_error_line
M.logical_line_at = logical_line_at
M.scan_logical_at = scan_logical_at
M.dir_map = dir_map
M.watch_run_output = watch_run_output
M.follow_tail = follow_tail
M.define_highlight = define_error_highlight

return M
