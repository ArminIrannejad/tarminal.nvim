--- tarminal.nvim — terminal runner / REPL integration.

local M = {}

local uv = vim.uv or vim.loop

-- "Linux" | "Darwin" | "FreeBSD" | "OpenBSD" | "NetBSD" | "Windows" | ...
local SYSNAME = (uv.os_uname() or {}).sysname or ""

---@alias tarminal.Follow
---| '"none"'   # stay in the code window
---| '"focus"'  # terminal window, normal mode
---| '"insert"' # terminal window, terminal-mode

---@alias tarminal.SplitPosition
---| '"auto"'   # follow 'splitbelow'
---| '"bottom"' # bottom, always
---| '"top"'    # top, always

---@class tarminal.Config
---@field split_height integer
---@field split_position tarminal.SplitPosition
---@field shell string
---@field follow_run tarminal.Follow
---@field follow_repl tarminal.Follow
---@field autosave boolean write the buffer before a run; false uses disk
---@field park_on_error boolean highlight errors and park on the first
---@field cell_marker string line that delimits REPL cells
---@field time_runs boolean `time` the run when a time binary exists
---@field banner boolean print a RUN[n] banner before each run
---@field runners table<string, string|tarminal.Runner> filetype -> run command
---@field compilers string[] program names built with `-o` then run
---@field repls table<string, string|tarminal.Repl> filetype -> REPL command
---@field error_patterns tarminal.ErrorPattern[] error formats, tried in order
---@field error_threshold integer min severity to park/step/collect (0 note, 1 warn, 2 error)
---@field quickfix tarminal.Quickfix

---@class tarminal.Quickfix
---@field open boolean open quickfix after collecting
---@field close_terminal boolean close the terminal after collecting

---@class tarminal.ErrorPattern
---@field pattern string Lua pattern matched against a whole line
---@field file integer capture index of the file
---@field lnum integer|nil capture index of the line
---@field col integer|nil capture index of the column
---@field type integer|string|nil capture index of a severity word, or a fixed severity
---@field resolve boolean|nil default true: file must exist on disk; false trusts the path

---@class tarminal.Runner
---@field cmd string run command
---@field run_binary boolean|nil true: build with `-o` then run the binary
---@field args string|nil flags appended after the file

---@class tarminal.Repl
---@field cmd string REPL command
---@field bracketed_paste boolean|nil false to send raw (can't parse paste escapes)
---@field block_open string|nil marker opening a multi-line block (ghci `:{`)
---@field block_close string|nil marker closing it (ghci `:}`)

-- path chars: no whitespace/colon/brackets/quotes (spaces/parens use the fallback)
local PATH = "([^%s:%(%)%[%]<>'\"]+)"

local defaults = {
  split_height = 12,
  split_position = "auto",
  shell = vim.env.SHELL or "/bin/bash",
  follow_run = "focus",
  follow_repl = "none",
  autosave = true,
  park_on_error = true,
  cell_marker = "# COMMAND ----------",
  time_runs = true,
  banner = true,
  runners = {
    python = "python",
    sh = "bash",
    lua = "lua",
    javascript = "node",
    go = "go run",
    haskell = "runghc",
    ocaml = "ocaml",
    c = "cc",
    rust = "rustc",
    odin = { cmd = "odin run", args = "-file" },
  },
  -- only `cmd <src> -o <out>` compilers; others need a run_binary runner
  compilers = {
    "cc",
    "gcc",
    "clang",
    "g++",
    "clang++",
    "c++",
    "rustc",
    "ghc",
    "swiftc",
    "gdc",
    "ocamlopt",
    "ocamlc",
  },
  repls = {
    python = "ipython",
    lua = "lua -i",
    javascript = "node",
    ruby = "irb",
    julia = "julia",
    r = "R",
    haskell = { cmd = "ghci", bracketed_paste = false, block_open = ":{", block_close = ":}" },
    ocaml = { cmd = "ocaml", bracketed_paste = false },
  },
  -- tried in order; add your own for tools these miss
  error_patterns = {
    { pattern = PATH .. ":(%d+):(%d+):%s*(%l+)", file = 1, lnum = 2, col = 3, type = 4 },
    { pattern = PATH .. ":(%d+):(%d+)", file = 1, lnum = 2, col = 3 },
    { pattern = PATH .. ":(%d+):", file = 1, lnum = 2 },
    { pattern = 'File "([^"]+)", line (%d+)', file = 1, lnum = 2 },
  },
  error_threshold = 0,
  quickfix = {
    open = true,
    close_terminal = true,
  },
}

M.config = vim.deepcopy(defaults)

local function terminal_split()
  local pos = M.config.split_position
  if pos == "auto" then
    pos = vim.o.splitbelow and "bottom" or "top"
  end
  vim.cmd(pos == "top" and "topleft split" or "botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, M.config.split_height)
  vim.wo.winfixheight = true
  return win
end

local function get_job_id(buf)
  return vim.b[buf].terminal_job_id
end

local function find_win_for_buf(buf)
  if not buf then
    return nil
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
end

local function ensure_window_for_buf(buf)
  local win = find_win_for_buf(buf)
  if win then
    return win
  end
  win = terminal_split()
  vim.api.nvim_win_set_buf(win, buf)
  return win
end

local function is_terminal_alive(buf)
  local job = get_job_id(buf)
  if not job then
    return false
  end
  return vim.fn.jobwait({ job }, 0)[1] == -1
end

---@return integer|nil buf
local function find_live_terminal(var_name, expected)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buftype == "terminal" and vim.b[buf][var_name] == expected then
      if is_terminal_alive(buf) then
        return buf
      end
      vim.api.nvim_buf_delete(buf, { force = true })
      return nil
    end
  end
end

---@param name string buffer name, e.g. "tarminal://shell"
---@return integer|nil buf, integer|nil win
local function open_shell_term(name)
  local win = terminal_split()
  -- jobstart (not :terminal); list form spawns the shell directly (jobpid = shell)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  local cmd = vim.split(M.config.shell, "%s+", { trimempty = true })
  local ok, job
  if vim.fn.has("nvim-0.11") == 1 then
    ok, job = pcall(vim.fn.jobstart, cmd, { term = true })
  else
    ok, job = pcall(vim.fn.termopen, cmd)
  end
  if not ok or type(job) ~= "number" or job <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    local msg = not ok and tostring(job):match("(E%d+:[^\n]*)")
    vim.notify(msg or ("tarminal: could not start shell: " .. M.config.shell), vim.log.levels.ERROR)
    return nil
  end
  vim.b[buf].term_cwd = vim.fn.getcwd()

  vim.opt_local.number = false
  vim.opt_local.relativenumber = false
  vim.opt_local.scrolloff = 0
  vim.bo[buf].filetype = "tarminal"
  pcall(vim.api.nvim_buf_set_name, buf, name)

  return buf, win
end

local function term_send(buf, text)
  vim.fn.chansend(get_job_id(buf), text)
end

-- leading space keeps it out of shell history (ignorespace)
local function term_send_command(buf, cmd)
  term_send(buf, " " .. cmd .. "\n")
end

local function term_cd(buf, dir)
  term_send_command(buf, "cd " .. vim.fn.shellescape(dir))
  vim.b[buf].term_cwd = dir
end

---@param follow tarminal.Follow
local function focus_after_send(term_win, code_win, follow)
  M._last_code_win = code_win
  vim.api.nvim_win_call(term_win, function()
    vim.cmd("normal! G")
  end)
  if follow == "insert" then
    vim.api.nvim_set_current_win(term_win)
    vim.cmd("startinsert")
  elseif follow == "focus" then
    vim.api.nvim_set_current_win(term_win)
  elseif vim.api.nvim_get_current_win() ~= code_win and vim.api.nvim_win_is_valid(code_win) then
    vim.api.nvim_set_current_win(code_win)
  end
end

-- job -> shell pid, or nil (dedupes the boilerplate the term_* wrappers share)
---@return integer|nil
local function term_pid(buf)
  local job = get_job_id(buf)
  if not job then
    return nil
  end
  local ok, pid = pcall(vim.fn.jobpid, job)
  if ok and pid and pid > 0 then
    return pid
  end
  return nil
end

-- process introspection: linux reads procfs; macos/bsd shell out. nil = unknown
local function linux_cwd(pid)
  return uv.fs_readlink("/proc/" .. pid .. "/cwd")
end

-- foreground job? pgrp vs tpgid from /proc/stat; dead group with no procs = idle
local function linux_busy(pid)
  local f = io.open("/proc/" .. pid .. "/stat", "r")
  if not f then
    return nil
  end
  local stat = f:read("*a") or ""
  f:close()
  -- comm may contain ")": parse after the last
  local rest = stat:match(".*%)%s+(.*)")
  if not rest then
    return nil
  end
  local fields = vim.split(rest, "%s+", { trimempty = true })
  local pgrp, tpgid = tonumber(fields[3]), tonumber(fields[6])
  if not pgrp or not tpgid or tpgid <= 0 then
    return nil
  end
  if tpgid == pgrp then
    return false
  end
  return uv.kill(-tpgid, 0) == 0
end

-- via /proc children; works without job control
local function linux_has_child(pid)
  local f = io.open("/proc/" .. pid .. "/task/" .. pid .. "/children", "r")
  if not f then
    return nil
  end
  local kids = f:read("*a") or ""
  f:close()
  return vim.trim(kids) ~= ""
end

-- macos/bsd: pgrep lists child pids; exit 0 iff any exist
local function pgrep_has_child(pid)
  local out = vim.fn.system({ "pgrep", "-P", tostring(pid) })
  return vim.v.shell_error == 0 and vim.trim(out) ~= ""
end

-- macos/bsd: foreground job? shell pgid vs terminal tpgid via ps, like linux_busy
local function ps_busy(pid)
  local out = vim.fn.system({ "ps", "-o", "pgid=", "-o", "tpgid=", "-p", tostring(pid) })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local pgid, tpgid = out:match("(%d+)%s+(%-?%d+)")
  pgid, tpgid = tonumber(pgid), tonumber(tpgid)
  if not pgid or not tpgid or tpgid <= 0 then
    return nil
  end
  if tpgid == pgid then
    return false
  end
  return uv.kill(-tpgid, 0) == 0
end

-- lsof path, resolved once ("" from exepath -> stock location)
local LSOF = vim.fn.exepath("lsof")
if LSOF == "" then
  LSOF = "/usr/sbin/lsof"
end

-- cwd from `lsof -Fn`: lines are p<pid>, fcwd, n<path>; split out to unit-test
local function parse_lsof_cwd(out)
  return out:match("\nn([^\n]+)") or out:match("^n([^\n]+)")
end

-- macOS has no procfs; ask lsof for just the cwd descriptor (-d cwd).
local function darwin_cwd(pid)
  local out = vim.fn.system({ LSOF, "-a", "-p", tostring(pid), "-d", "cwd", "-Fn" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return parse_lsof_cwd(out)
end

-- TODO(bsd): procstat -f <pid> (or fstat) for cwd; nil -> term_cwd's cached fallback
local function bsd_cwd(_)
  return nil
end

local IS_BSD = SYSNAME == "FreeBSD" or SYSNAME == "OpenBSD" or SYSNAME == "NetBSD"

-- buf -> {tick, cwd}: memoize the shell-out cwd; a `cd` bumps changedtick, expiring it
local cwd_cache = {}

local function cached_cwd(buf, pid, provider)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = cwd_cache[buf]
  if c and c.tick == tick then
    return c.cwd
  end
  local cwd = provider(pid)
  cwd_cache[buf] = { tick = tick, cwd = cwd }
  return cwd
end

---@return string|nil
local function term_cwd(buf)
  local pid = term_pid(buf)
  if pid then
    local cwd
    if SYSNAME == "Linux" then
      cwd = linux_cwd(pid) -- procfs readlink is free; no cache needed
    elseif SYSNAME == "Darwin" then
      cwd = cached_cwd(buf, pid, darwin_cwd)
    elseif IS_BSD then
      cwd = cached_cwd(buf, pid, bsd_cwd)
    end
    if cwd then
      return cwd
    end
  end
  return vim.b[buf].term_cwd
end

---@return boolean|nil busy nil when undeterminable
local function term_busy(buf)
  local pid = term_pid(buf)
  if not pid then
    return nil
  end
  if SYSNAME == "Linux" then
    return linux_busy(pid)
  elseif SYSNAME == "Darwin" or IS_BSD then
    return ps_busy(pid)
  end
  return nil
end

-- shell has a live child (the REPL)?
---@return boolean|nil
local function shell_has_child(buf)
  local pid = term_pid(buf)
  if not pid then
    return nil
  end
  if SYSNAME == "Linux" then
    return linux_has_child(pid)
  elseif SYSNAME == "Darwin" or IS_BSD then
    return pgrep_has_child(pid)
  end
  return nil
end

-- wait for the REPL to become the shell's child; re-check to reject a flicker
---@return boolean
local function wait_for_repl(buf)
  if shell_has_child(buf) == nil then
    return true
  end
  return vim.wait(2000, function()
    return shell_has_child(buf)
  end, 20) and shell_has_child(buf) == true
end

---@return string|nil
local function resolve_file(path, term_buf)
  if path:sub(1, 1) == "~" then
    path = vim.fn.expand(path)
  end
  local candidates
  if path:sub(1, 1) == "/" then
    candidates = { path }
  else
    candidates = {}
    local cwd = term_cwd(term_buf)
    if cwd then
      candidates[#candidates + 1] = cwd .. "/" .. path
    end
    candidates[#candidates + 1] = vim.fn.getcwd() .. "/" .. path
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
  for _, pat in ipairs(M.config.error_patterns) do
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
        break -- leftmost hit for this pattern
      end
      init = e + 1 -- didn't resolve; keep scanning
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
    -- allow parens (paths like `/tmp/foo(audit).c`); resolve_file_suffix unwraps
    local s, e, f, l, c = line:find("([^:'\"]+):(%d+):?(%d*)", init)
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
  local win = find_win_for_buf(term_buf)
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
  if M._last_code_win then
    wins[#wins + 1] = M._last_code_win
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
local WATCH_TIMEOUT = 30000 -- of silence; new output resets it

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
local function watch_run_errors(term_buf, banner_token, start_row)
  if M._watch_timer then
    M._watch_timer:stop()
    M._watch_timer:close()
    M._watch_timer = nil
  end

  local elapsed = 0
  local pinned = banner_token == nil -- no banner, nothing to pin to
  local parked = false
  local seen = false -- run output scanned at least once
  local last_tick = vim.api.nvim_buf_get_changedtick(term_buf)
  local timer = uv.new_timer()
  M._watch_timer = timer

  local function stop()
    timer:stop()
    timer:close()
    if M._watch_timer == timer then
      M._watch_timer = nil
    end
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
        local busy = term_busy(term_buf)
        if (seen and busy == false) or (busy ~= true and elapsed > WATCH_TIMEOUT) then
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

      local win = find_win_for_buf(term_buf)
      -- don't steal the cursor while typing
      local typing = win == vim.api.nvim_get_current_win() and vim.api.nvim_get_mode().mode:sub(1, 1) == "t"

      if not pinned then
        pinned = true
        if win and not typing then
          vim.api.nvim_win_call(win, function()
            vim.fn.winrestview({ topline = banner_row, lnum = banner_row, col = 0 })
          end)
        end
      end

      vim.api.nvim_buf_clear_namespace(term_buf, ns, banner_row, -1)
      local width = pty_width(term_buf)
      local i = banner_row + 1
      while i <= #lines do
        local logical, first, last = logical_line_at(lines, i, width)
        local file, _, _, span_s, span_e, sev = parse_error_line(logical, term_buf)
        if file then
          -- highlight all; park only at/above the threshold
          highlight_span(term_buf, lines, first, last, span_s, span_e, severity_hl(sev))
          if not parked and sev >= M.config.error_threshold then
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
    if file and sev >= M.config.error_threshold then
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
    -- bannerless: scan below the prompt
    start_row = vim.b[term_buf].run_start_row + 1
  end

  local items = {}
  local i = start_row
  while i <= #lines do
    local logical, _, last = logical_line_at(lines, i, width)
    local file, lnum, col, _, _, sev = parse_error_line(logical, term_buf)
    if file and sev >= M.config.error_threshold then
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
  local qf = M.config.quickfix
  if qf.close_terminal then
    local win = find_win_for_buf(term_buf)
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
  local buf = find_live_terminal("is_shell", true)
  if buf then
    return buf, ensure_window_for_buf(buf)
  end
  local win
  buf, win = open_shell_term("tarminal://shell")
  if not buf then
    return nil
  end
  vim.b[buf].is_shell = true
  return buf, win
end

function M.toggle()
  local buf = find_live_terminal("is_shell", true)
  local win = find_win_for_buf(buf)
  if win then
    if not pcall(vim.api.nvim_win_close, win, false) then
      -- last window (E444): swap in an empty buffer instead
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

  -- a busy shell would eat the send as stdin; show it so it can be interrupted
  local existing = find_live_terminal("is_shell", true)
  if existing and term_busy(existing) then
    ensure_window_for_buf(existing)
    vim.api.nvim_set_current_win(code_win)
    vim.notify("Terminal is busy; interrupt the running command first", vim.log.levels.WARN)
    return
  end

  local term_buf, term_win = get_or_create_shell_term()
  if not term_buf then
    vim.api.nvim_set_current_win(code_win)
    return
  end

  -- terminal rewrites lines in place; drop old highlights
  vim.api.nvim_buf_clear_namespace(term_buf, ns, 0, -1)

  M._run_id = (M._run_id or 0) + 1

  local banner, start_row, full
  if M.config.banner then
    banner = ("RUN[%d]"):format(M._run_id)

    -- feed newlines then home cursor: keeps prior runs scrollable (unlike clear)
    local scroll = vim.api.nvim_win_get_height(term_win)
    full = table.concat({
      "cd " .. vim.fn.shellescape(dir),
      "printf '" .. ("\\n"):rep(scroll) .. "\\033[H'",
      "printf '\\n===== RUN[%d]: %s =====\\n' " .. M._run_id .. " \"$(date '+%H:%M:%S')\"",
      "\n" .. cmd,
    }, " && ")
  else
    start_row = last_content_row(term_buf)
    full = "cd " .. vim.fn.shellescape(dir) .. " && " .. cmd
  end

  if M.config.park_on_error then
    watch_run_errors(term_buf, banner, start_row)
  end
  term_send_command(term_buf, full)
  vim.b[term_buf].term_cwd = dir
  vim.b[term_buf].run_banner = banner
  vim.b[term_buf].run_start_row = start_row

  focus_after_send(term_win, code_win, M.config.follow_run)
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
  for _, name in ipairs(M.config.compilers) do
    if exe == name or unversioned == name then
      return true
    end
  end
  return false
end

---@return string|nil cmd, boolean run_binary, string|nil args
local function runner_spec(ft)
  local spec = M.config.runners[ft]
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
  local time = M.config.time_runs and vim.fn.executable("time") == 1 and "time " or ""
  local file = vim.fn.shellescape(ctx.file)
  if run_binary then
    local stem = ctx.stem
    if stem == vim.fn.fnamemodify(ctx.file, ":t") then
      stem = stem .. ".out"
    end
    local out = vim.fn.shellescape(stem)
    return ("%s %s%s -o %s && %s./%s"):format(runner, file, suffix, out, time, out)
  end
  return time .. runner .. " " .. file .. suffix
end

---@return boolean ok
local function update_buffer(buf)
  if not M.config.autosave then
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
    ctx = M._last_run
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
    M._last_run = ctx
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
    vim.ui.input({ prompt = "exec: ", default = M._last_exec_cmd, completion = "shellcmd" }, function(text)
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

  M._last_exec_cmd = cmd
  M._last_exec_dir = vim.fn.getcwd()
  execute_in_shell(cmd, M._last_exec_dir)
end

-- extend col to the last byte of its char (getpos gives the first byte)
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
  local lines =
    vim.api.nvim_buf_get_text(0, line_start - 1, col_start - 1, line_end - 1, char_end_col(end_line, col_end), {})
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
  local spec = M.config.repls[ft]
  if type(spec) == "table" then
    return spec.cmd, spec.bracketed_paste ~= false, spec.block_open, spec.block_close
  end
  return spec, true
end

---@param ft string filetype whose REPL to reuse or start
---@return integer|nil buf, integer|nil win
local function get_or_start_repl(ft)
  local repl_cmd = repl_spec(ft)

  local buf = find_live_terminal("repl_ft", ft)
  if buf then
    -- REPL exited but the shell lives: relaunch it, else source hits the shell
    if repl_cmd and shell_has_child(buf) == false then
      term_send_command(buf, repl_cmd)
      if not wait_for_repl(buf) then
        vim.notify("REPL is not running: " .. repl_cmd, vim.log.levels.ERROR)
        return
      end
    end
    return buf, ensure_window_for_buf(buf)
  end

  if not repl_cmd then
    vim.notify("No REPL configured for filetype: " .. ft, vim.log.levels.WARN)
    return
  end

  local dir = vim.fn.expand("%:p:h")
  local win
  buf, win = open_shell_term("tarminal://repl:" .. ft)
  if not buf then
    return nil
  end
  term_cd(buf, dir)
  term_send_command(buf, repl_cmd)
  vim.b[buf].repl_ft = ft
  -- ensure the REPL came up before sending, else source hits the shell
  if not wait_for_repl(buf) then
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
  term_send(repl_buf, text)
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
  focus_after_send(repl_win, code_win, M.config.follow_repl)
end

local function line_is_marker(s)
  return M.config.cell_marker ~= "" and vim.trim(s) == M.config.cell_marker
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
  focus_after_send(repl_win, code_win, M.config.follow_repl)
end

local function define_error_highlight()
  local err = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  vim.api.nvim_set_hl(0, "TarminalError", { fg = err.fg or "Red", bold = true })
  local warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
  vim.api.nvim_set_hl(0, "TarminalWarning", { fg = warn.fg or "Yellow", bold = true })
end

--- Settings only; tarminal never creates keymaps.
---@param opts tarminal.Config|nil merged over the defaults
function M.setup(opts)
  opts = opts or {}
  -- error_patterns is a list; prepend user's to built-ins (deep_extend index-merges)
  local extra = opts.error_patterns
  if extra then
    opts = vim.tbl_extend("force", {}, opts) -- shallow copy; don't mutate caller
    opts.error_patterns = nil
  end
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if extra then
    M.config.error_patterns = vim.list_extend(vim.deepcopy(extra), M.config.error_patterns)
  end
  local group = vim.api.nvim_create_augroup("tarminal-highlight", { clear = true })

  define_error_highlight()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_error_highlight,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      cwd_cache[ev.buf] = nil
    end,
  })
end

return M
