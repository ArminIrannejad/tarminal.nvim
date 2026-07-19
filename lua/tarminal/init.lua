--- tarminal.nvim — terminal runner / REPL integration.

local M = {}

local uv = vim.uv or vim.loop

--- Where focus goes after sending something to a terminal:
---@alias tarminal.Follow
---| '"none"'   # stay in the code window
---| '"focus"'  # move to the terminal window, normal mode
---| '"insert"' # move to the terminal window and enter terminal-mode

--- Where the terminal split opens (always full-width):
---@alias tarminal.SplitPosition
---| '"auto"'   # follow 'splitbelow': bottom when set, top otherwise
---| '"bottom"' # bottom, regardless of 'splitbelow'
---| '"top"'    # top, regardless of 'splitbelow'

---@class tarminal.Config
---@field split_height integer height of the terminal split
---@field split_position tarminal.SplitPosition
---@field shell string
---@field follow_run tarminal.Follow
---@field follow_repl tarminal.Follow
---@field park_on_error boolean after a run, highlight error locations and park the cursor on the first one
---@field cell_marker string line that delimits REPL cells
---@field time_runs boolean `time` the run when a `time` binary is installed (for compiled files: the produced binary)
---@field banner boolean print a `===== RUN[n]: <time> =====` line before each run's output and pin the view to it; false prints nothing extra
---@field runners table<string, string|tarminal.Runner> filetype -> command the file is run with; compilers are recognized by name
---@field compilers string[] program names treated as compilers: the file is built with `-o` first, then the binary is run
---@field repls table<string, string|tarminal.Repl> filetype -> interactive REPL command
---@field quickfix tarminal.Quickfix

--- What errors_to_quickfix does besides populating the quickfix list.
---@class tarminal.Quickfix
---@field open boolean open the quickfix window after collecting
---@field close_terminal boolean close the terminal window after collecting

--- A `runners` entry with options; a plain command string infers
--- compile-then-run from the command's program name (see `compilers`).
---@class tarminal.Runner
---@field cmd string command the file is run with
---@field compile boolean|nil true: build with `-o` first, then run the
---binary (for compilers not recognized by name); false: never compile,
---run the file with the command directly

--- A `repls` entry with options; a plain command string means all defaults.
---@class tarminal.Repl
---@field cmd string interactive REPL command
---@field bracketed_paste boolean|nil false for REPLs that read raw stdin and
---would see the paste escape sequences as input (the stock ocaml toplevel)

local defaults = {
  split_height = 12,
  split_position = "auto",
  shell = vim.env.SHELL or "/bin/bash",
  follow_run = "focus",
  follow_repl = "none",
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
    fortran = "gfortran",
  },
  -- Only compilers that accept `<source> -o <out>` and produce a directly
  -- executable result belong here: the build command is composed exactly
  -- that way. Compilers with other conventions (javac, scalac, luac, dmd,
  -- `go build`, `zig build-exe`, ...) can't be listed — configure those as
  -- a runner with an explicit `compile` flag, or run them directly.
  compilers = {
    "cc",
    "gcc",
    "clang",
    "g++",
    "clang++",
    "c++",
    "tcc",
    "icc",
    "icpc",
    "icx",
    "icpx",
    "nvcc",
    "gfortran",
    "flang",
    "flang-new",
    "ifort",
    "ifx",
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
    haskell = "ghci",
    ocaml = { cmd = "ocaml", bracketed_paste = false },
  },
  quickfix = {
    open = true,
    close_terminal = true,
  },
}

M.config = vim.deepcopy(defaults)

--- Open the full-width terminal split, at the position `split_position`
--- asks for — with "auto", wherever the user's 'splitbelow' puts splits.
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
  -- A terminal buffer is shared, but its split is local to the current tab.
  -- Looking through every tab here would make toggle() close a split in a
  -- different tab and make run() unexpectedly switch tabs.
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

--- Find the terminal buffer tagged with `b:<var_name> == expected`,
--- deleting it instead if its job has exited.
---@param var_name string
---@param expected any
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
---@return integer buf, integer win
local function open_shell_term(name)
  local win = terminal_split()
  -- Spawn in a fresh buffer via jobstart/termopen instead of :terminal,
  -- whose Ex parsing would expand % and # and split the command on |.
  -- The command is passed as a list, so the shell is spawned *directly*:
  -- a string would be wrapped in ['shell' -c "cmd"], and shells that fork
  -- instead of exec-ing there (dash) would make jobpid point at the
  -- wrapper — breaking the foreground-job check and /proc cwd resolution.
  vim.cmd("enew")
  local cmd = vim.split(M.config.shell, "%s+", { trimempty = true })
  if vim.fn.has("nvim-0.11") == 1 then
    vim.fn.jobstart(cmd, { term = true })
  else
    vim.fn.termopen(cmd)
  end
  local buf = vim.api.nvim_get_current_buf()
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

local function term_cd(buf, dir)
  term_send(buf, "cd " .. vim.fn.shellescape(dir) .. "\n")
  vim.b[buf].term_cwd = dir
end

--- Scroll the terminal to the bottom, then place focus according to `follow`.
---@param term_win integer
---@param code_win integer window we were editing in
---@param follow tarminal.Follow
local function focus_after_send(term_win, code_win, follow)
  M._last_code_win = code_win
  -- scroll without entering the window: with follow = "none", entering and
  -- leaving would fire WinEnter/BufEnter autocmds twice and flicker
  vim.api.nvim_win_call(term_win, function()
    vim.cmd("normal! G")
  end)
  if follow == "insert" then
    vim.api.nvim_set_current_win(term_win)
    vim.cmd("startinsert")
  elseif follow == "focus" then
    vim.api.nvim_set_current_win(term_win)
  elseif vim.api.nvim_get_current_win() ~= code_win and vim.api.nvim_win_is_valid(code_win) then
    -- opening the split moved focus into the terminal: return to the code
    vim.api.nvim_set_current_win(code_win)
  end
end

-- ============================================================================
-- Error locations: <CR> on an error line in the terminal jumps to it
-- ============================================================================

--- Working directory of the terminal's shell (via /proc, falling back to the
--- last directory we cd'd it into), so relative paths in errors resolve.
---@param buf integer terminal buffer
---@return string|nil
local function term_cwd(buf)
  local job = get_job_id(buf)
  if job then
    local ok, pid = pcall(vim.fn.jobpid, job)
    if ok and pid and pid > 0 then
      local cwd = uv.fs_readlink("/proc/" .. pid .. "/cwd")
      if cwd then
        return cwd
      end
    end
  end
  return vim.b[buf].term_cwd
end

--- Whether the terminal's shell currently has a foreground job. While a
--- command runs, its process group owns the pty; at the prompt the shell's
--- own group does. Compared via /proc/<pid>/stat, whose fields after the
--- comm are: state ppid pgrp session tty_nr tpgid ...
---
--- Some shells (dash) never take the foreground back at the prompt: tpgid
--- keeps pointing at the exited child's process group. A foreground group
--- with no living processes is therefore idle, not busy — probed with
--- kill(-pgid, 0).
---@param buf integer terminal buffer
---@return boolean|nil busy nil when it cannot be determined
local function term_busy(buf)
  local job = get_job_id(buf)
  if not job then
    return nil
  end
  local ok, pid = pcall(vim.fn.jobpid, job)
  if not ok or not pid or pid <= 0 then
    return nil
  end
  local f = io.open("/proc/" .. pid .. "/stat", "r")
  if not f then
    return nil
  end
  local stat = f:read("*a") or ""
  f:close()
  -- the comm field may itself contain ")": parse after the last one
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

---@param path string absolute, relative or ~ path from an error message
---@param term_buf integer terminal buffer the message appeared in
---@return string|nil # absolute path to an existing file
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

--- Resolve a captured location candidate, allowing diagnostic tools to put a
--- prefix before the path. For example, sbt emits
--- `[error] /path/Main.scala:12:4`. Try the complete candidate first so paths
--- containing spaces keep working, then successively discard leading words.
---@param candidate string
---@param term_buf integer
---@return string|nil path, integer|nil offset byte offset of the path in `candidate`
local function resolve_file_suffix(candidate, term_buf)
  local trimmed = vim.trim(candidate)
  local trim_offset = candidate:find(trimmed, 1, true) - 1
  local start = 1

  while true do
    local path = resolve_file(trimmed:sub(start), term_buf)
    if path then
      return path, trim_offset + start - 1
    end

    local _, prefix_end = trimmed:find("%s+", start)
    if not prefix_end then
      return
    end
    start = prefix_end + 1
  end
end

--- First location on the line that points at a real file. Covers
--- cc/go/ghc/lua style ("foo.c:12:5:") and python/ocaml style
--- ('File "foo.py", line 12') messages.
---@param line string
---@param term_buf integer
---@return string|nil file, integer|nil lnum, integer|nil col
---@return integer|nil span_s, integer|nil span_e 1-based inclusive byte range of the match in `line`
local function parse_error_line(line, term_buf)
  local s, e, file, lnum = line:find('File "([^"]+)", line (%d+)')
  if file then
    local path = resolve_file(file, term_buf)
    if path then
      return path, tonumber(lnum), nil, s, e
    end
  end
  local init = 1
  while true do
    local f, l, c
    s, e, f, l, c = line:find("([^:'\"()]+):(%d+):?(%d*)", init)
    if not s then
      break
    end
    local path, offset = resolve_file_suffix(f, term_buf)
    if path then
      return path, tonumber(l), tonumber(c), s + offset, e
    end
    init = e + 1
  end
end

--- Width the terminal wraps its output at. The window's *current* width is
--- the right answer: Neovim >= 0.10 re-wraps terminal content whenever the
--- window is resized, so buffer lines always follow the live width. (0.9
--- doesn't re-wrap — there, output printed before a resize can join wrong,
--- and a shrink truncates those lines anyway, losing the tail for good.)
---@param term_buf integer
---@return integer
local function pty_width(term_buf)
  local win = find_win_for_buf(term_buf)
  return win and vim.api.nvim_win_get_width(win) or vim.o.columns
end

--- Terminal output hard-wraps at the PTY width, splitting long paths across
--- physical lines. Rebuild the logical line around `row` by joining
--- full-width lines with their continuations.
---@param lines string[] physical buffer lines
---@param row integer 1-based index into lines
---@param width integer PTY width
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

--- Window a jump should land in: the code window we last ran from, else the
--- previous window, else any window showing a normal file buffer. Only
--- windows in the current tab qualify — the last code window may live in
--- another tab, and jumping there would switch tabs unexpectedly.
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

--- The error-navigation functions read the current buffer as terminal
--- output (and errors_to_quickfix may close its window), so refuse to
--- operate on anything that is not a terminal.
---@return integer|nil term_buf
local function current_term_buf()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "terminal" then
    vim.notify("Not in a terminal buffer", vim.log.levels.WARN)
    return nil
  end
  return buf
end

--- Jump to the file location on the current terminal line (mapped to <CR>
--- in terminal-buffer normal mode).
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
  -- linkers emit "file:0:" locations — clamp both ends of the range
  lnum = math.min(math.max(lnum, 1), vim.api.nvim_buf_line_count(buf))
  vim.api.nvim_win_set_cursor(win, { lnum, math.max((col or 1) - 1, 0) })
  vim.cmd("normal! zz")
end

local WATCH_INTERVAL = 200
-- of terminal *silence* — new output resets it, so long builds stay watched
local WATCH_TIMEOUT = 30000

local ns = vim.api.nvim_create_namespace("tarminal.errors")

--- Highlight a span of a logical line (1-based inclusive byte range) across
--- the physical lines it wraps over.
---@param term_buf integer
---@param lines string[]
---@param first_row integer physical row the logical line starts on
---@param last_row integer physical row it ends on
---@param span_s integer
---@param span_e integer
local function highlight_span(term_buf, lines, first_row, last_row, span_s, span_e)
  local off = 0
  for row = first_row, last_row do
    local len = #lines[row]
    local cs = math.max(span_s - off, 1)
    local ce = math.min(span_e - off, len)
    if cs <= ce then
      vim.api.nvim_buf_set_extmark(term_buf, ns, row - 1, cs - 1, {
        end_col = ce,
        hl_group = "TarminalError",
        strict = false,
      })
    end
    off = off + len
  end
end

--- Row of the last printed run banner. The token is assembled by printf at
--- run time (from a %d argument), so the echoed command never contains the
--- finished string; requiring the banner ruler at the start of the line
--- additionally guards against program output that quotes a banner.
---@param lines string[]
---@param banner_token string
---@return integer|nil row
local function find_banner_row(lines, banner_token)
  for i = #lines, 1, -1 do
    if lines[i]:match("^=====") and lines[i]:find(banner_token, 1, true) then
      return i
    end
  end
end

--- Last row holding text — before a run is sent, the prompt line — so a
--- bannerless run's output can be scanned from below it. (Terminal buffers
--- keep trailing blank screen lines, so the line count would overshoot.)
---@param buf integer terminal buffer
---@return integer row 0 when the buffer is entirely blank
local function last_content_row(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i] ~= "" then
      return i
    end
  end
  return 0
end

--- Watch the terminal output printed after this run's banner (with banners
--- disabled: after `start_row`): pin the window view so the banner starts
--- at the top, highlight every error location and park the cursor on the
--- first one, so a single <CR> jumps to it. Output arrives async, so this
--- polls: it finishes once the run's output has been scanned and the shell
--- holds the pty foreground again (i.e. the run exited, whatever its
--- status), and gives up quietly after WATCH_TIMEOUT of terminal silence —
--- e.g. when the command never produced its banner, or in a shell without
--- job control, where completion cannot be observed.
---@param term_buf integer
---@param banner_token string|nil unique marker this run prints before its output
---@param start_row integer|nil row the run's output starts after, when bannerless
local function watch_run_errors(term_buf, banner_token, start_row)
  if M._watch_timer then
    M._watch_timer:stop()
    M._watch_timer:close()
    M._watch_timer = nil
  end

  local elapsed = 0
  local pinned = banner_token == nil -- without a banner there is nothing to pin to
  local parked = false
  local seen = false -- this run's output has been scanned at least once
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
        -- the output settled and the shell holds the foreground again: the
        -- run is over. (term_busy nil — no job control — never matches, so
        -- there only prolonged silence gives up.)
        if elapsed > WATCH_TIMEOUT or (seen and term_busy(term_buf) == false) then
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
      -- don't steal the cursor while typing in the terminal
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
        local file, _, _, span_s, span_e = parse_error_line(logical, term_buf)
        if file then
          highlight_span(term_buf, lines, first, last, span_s, span_e)
          if not parked then
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
    if parse_error_line(logical, term_buf) then
      vim.api.nvim_win_set_cursor(0, { first, 0 })
      return
    end
    i = dir > 0 and last + 1 or first - 1
  end
  vim.notify("No more error locations", vim.log.levels.WARN)
end

--- Move the cursor to the next error location in the terminal.
function M.next_error()
  goto_error(1)
end

--- Move the cursor to the previous error location in the terminal.
function M.prev_error()
  goto_error(-1)
end

--- Collect the error locations from the last run (or the whole scrollback if
--- this terminal never ran anything) into the quickfix list. Whether the
--- terminal window is closed and quickfix opened afterwards is controlled by
--- `config.quickfix`.
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
    -- bannerless run: scan below where the prompt was when it was sent
    start_row = vim.b[term_buf].run_start_row + 1
  end

  local items = {}
  local i = start_row
  while i <= #lines do
    local logical, _, last = logical_line_at(lines, i, width)
    local file, lnum, col = parse_error_line(logical, term_buf)
    if file then
      items[#items + 1] = {
        filename = file,
        lnum = lnum,
        col = col or 1,
        text = vim.trim(logical),
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
    if win then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
  if qf.open then
    vim.cmd("botright copen")
  else
    vim.notify(("%d error location(s) collected into quickfix"):format(#items), vim.log.levels.INFO)
  end
end

-- ============================================================================
-- Shared shell terminal: toggled, reused by run()
-- ============================================================================

local function get_or_create_shell_term()
  local buf = find_live_terminal("is_shell", true)
  if buf then
    return buf, ensure_window_for_buf(buf)
  end
  local win
  buf, win = open_shell_term("tarminal://shell")
  vim.b[buf].is_shell = true
  return buf, win
end

--- Show/hide the shared shell terminal.
function M.toggle()
  local buf = find_live_terminal("is_shell", true)
  local win = find_win_for_buf(buf)
  if win then
    if not pcall(vim.api.nvim_win_close, win, false) then
      -- the terminal is the last window (E444): hide it by swapping in an
      -- empty buffer instead of closing the window
      vim.api.nvim_win_call(win, function()
        vim.cmd("enew")
      end)
    end
  else
    get_or_create_shell_term()
  end
end

---@class tarminal.RunContext
---@field file string
---@field stem string
---@field dir string
---@field ft string

--- Whether the runner's program is a known compiler. Matched against the
--- first word, ignoring a leading path and a trailing version suffix, so
--- "/usr/bin/clang-17 -Wall" matches "clang".
---@param runner string
---@return boolean
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

--- Normalize a `runners` entry: a plain string is the command, with
--- compile-then-run inferred from its program name; a table carries the
--- command plus an explicit `compile` override (see tarminal.Runner).
---@param ft string
---@return string|nil cmd, boolean compile
local function runner_spec(ft)
  local spec = M.config.runners[ft]
  local cmd, compile = spec, nil
  if type(spec) == "table" then
    cmd, compile = spec.cmd, spec.compile
  end
  if compile == nil then
    compile = cmd ~= nil and is_compiler(cmd)
  end
  return cmd, compile
end

--- Build the shell command that runs a file: the runner with the file
--- appended (`python foo.py`). When the runner compiles (an explicit
--- `compile = true`, or a program listed in `config.compilers`), the file
--- is built first and the result is run (`cc foo.c -o foo && ./foo`);
--- `time_runs` times the run, not the build.
--- Timing requires a `time` binary — the shell keyword alone isn't relied
--- on, so the command works in any POSIX shell; without the binary the
--- prefix is skipped. An extensionless file compiles to `<name>.out` — its
--- stem *is* the filename, and `-o` would overwrite the source.
---@param ctx tarminal.RunContext
---@return string|nil
local function build_runner_command(ctx)
  local runner, compile = runner_spec(ctx.ft)
  if not runner then
    return
  end

  local time = M.config.time_runs and vim.fn.executable("time") == 1 and "time " or ""
  local file = vim.fn.shellescape(ctx.file)
  if compile then
    local stem = ctx.stem
    if stem == vim.fn.fnamemodify(ctx.file, ":t") then
      stem = stem .. ".out"
    end
    local out = vim.fn.shellescape(stem)
    return ("%s %s -o %s && %s./%s"):format(runner, file, out, time, out)
  end
  return time .. runner .. " " .. file
end

--- Write `buf` if it has unsaved changes. A failure (readonly, missing
--- directory, ...) is reported, so a run doesn't silently use the stale
--- on-disk version.
---@param buf integer
---@return boolean ok
local function update_buffer(buf)
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent update")
  end)
  if not ok then
    err = tostring(err)
    vim.notify(err:match("(E%d+:[^\n]*)") or err, vim.log.levels.ERROR)
  end
  return ok
end

--- Save and run the current file in the shared shell terminal. When invoked
--- from the terminal itself (or any non-file buffer), re-run the last run.
function M.run()
  local ctx
  local current_file = vim.fn.expand("%:p")
  if vim.bo.buftype == "" and current_file ~= "" then
    if not update_buffer(vim.api.nvim_get_current_buf()) then
      return
    end
    ctx = {
      file = current_file,
      stem = vim.fn.expand("%:t:r"),
      dir = vim.fn.fnamemodify(current_file, ":h"),
      ft = vim.bo.filetype,
    }
    M._last_run = ctx
  else
    ctx = M._last_run
    if not ctx then
      vim.notify("Nothing to run from here", vim.log.levels.WARN)
      return
    end
    -- a re-run executes the file from disk: save its buffer too if it is
    -- loaded with edits made since the original run
    local src = vim.fn.bufnr(ctx.file)
    if src ~= -1 and not update_buffer(src) then
      return
    end
  end

  local runner_cmd = build_runner_command(ctx)
  if not runner_cmd then
    vim.notify("No runner configured for filetype: " .. ctx.ft, vim.log.levels.WARN)
    return
  end

  local code_win = vim.api.nvim_get_current_win()

  -- If the previous command is still in the terminal's foreground, sending
  -- now would type into that program's stdin instead of the shell. Show the
  -- terminal so the user can see (and interrupt) what is running. Only a
  -- pre-existing shell can be busy; a fresh one is skipped so its startup
  -- files can't false-positive the check.
  local existing = find_live_terminal("is_shell", true)
  if existing and term_busy(existing) then
    ensure_window_for_buf(existing)
    vim.api.nvim_set_current_win(code_win)
    vim.notify("Terminal is busy; interrupt the running command first", vim.log.levels.WARN)
    return
  end

  local term_buf, term_win = get_or_create_shell_term()

  -- The terminal rewrites screen lines in place, so highlights left over from
  -- an earlier run can end up on this run's banner or output. Start clean.
  vim.api.nvim_buf_clear_namespace(term_buf, ns, 0, -1)

  M._run_id = (M._run_id or 0) + 1

  local banner, start_row, cmd
  if M.config.banner then
    banner = ("RUN[%d]"):format(M._run_id)

    -- Feed the screen into scrollback with newlines before homing the
    -- cursor: an ANSI scroll (or `clear`) erases the scrolled-out lines,
    -- newline-driven scrolling preserves them, so previous runs stay
    -- scrollable. The watcher pins the window view to this run's banner so
    -- it still starts at the top.
    --
    -- The banner token is assembled by printf from a %d argument, so the
    -- echoed command never contains the finished token and can't be
    -- mistaken for a banner, however the echo wraps.
    local scroll = vim.api.nvim_win_get_height(term_win)
    cmd = table.concat({
      "cd " .. vim.fn.shellescape(ctx.dir),
      "printf '" .. ("\\n"):rep(scroll) .. "\\033[H'",
      "printf '\\n===== RUN[%d]: %s =====\\n' " .. M._run_id .. " \"$(date '+%H:%M:%S')\"",
      "\n" .. runner_cmd,
    }, " && ") .. "\n"
  else
    -- no banner, no screen feed: output just appends, and the watcher
    -- scans whatever is printed below the current prompt line
    start_row = last_content_row(term_buf)
    cmd = "cd " .. vim.fn.shellescape(ctx.dir) .. " && " .. runner_cmd .. "\n"
  end

  if M.config.park_on_error then
    watch_run_errors(term_buf, banner, start_row)
  end
  term_send(term_buf, cmd)
  vim.b[term_buf].term_cwd = ctx.dir
  vim.b[term_buf].run_banner = banner
  vim.b[term_buf].run_start_row = start_row

  focus_after_send(term_win, code_win, M.config.follow_run)
end

-- ============================================================================
-- REPL: send visual selection or "cell"
-- ============================================================================

--- getpos() columns point at the *first* byte of a character; extend `col`
--- to that character's last byte (clamped to the line) so a multibyte
--- character at the end of a selection is not cut in half.
---@param line string
---@param col integer 1-based byte column
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
    local left, right = math.min(col_start, col_end), math.max(col_start, col_end)
    local lines = vim.api.nvim_buf_get_lines(0, line_start - 1, line_end, false)
    for i, line in ipairs(lines) do
      -- the block's byte columns can land mid-character on other lines
      local l = left
      if l >= 1 and l <= #line then
        l = l + vim.str_utf_start(line, l)
      end
      lines[i] = line:sub(l, char_end_col(line, right))
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

--- Normalize a `repls` entry: a plain string is the REPL command with all
--- defaults; a table carries the command plus options (see tarminal.Repl).
---@param ft string
---@return string|nil cmd, boolean bracketed_paste
local function repl_spec(ft)
  local spec = M.config.repls[ft]
  if type(spec) == "table" then
    return spec.cmd, spec.bracketed_paste ~= false
  end
  return spec, true
end

---@param ft string filetype whose REPL to reuse or start
---@return integer|nil buf, integer|nil win
local function get_or_start_repl(ft)
  local buf = find_live_terminal("repl_ft", ft)
  if buf then
    return buf, ensure_window_for_buf(buf)
  end

  local repl_cmd = repl_spec(ft)
  if not repl_cmd then
    vim.notify("No REPL configured for filetype: " .. ft, vim.log.levels.WARN)
    return
  end

  local dir = vim.fn.expand("%:p:h")
  local win
  buf, win = open_shell_term("tarminal://repl:" .. ft)
  term_cd(buf, dir)
  term_send(buf, repl_cmd .. "\n")
  vim.b[buf].repl_ft = ft
  return buf, win
end

--- Send text bracketed-paste wrapped, so multi-line blocks paste cleanly —
--- unless the REPL's entry disables it, in which case the text is sent raw.
---@param repl_buf integer
---@param text string
local function send_to_repl(repl_buf, text)
  if not text:match("\n$") then
    text = text .. "\n"
  end

  local _, bracketed = repl_spec(vim.b[repl_buf].repl_ft)
  if bracketed then
    text = "\x1b[200~" .. text .. "\x1b[201~\n"
  end
  term_send(repl_buf, text)
end

--- Send the visual selection, or an explicit command range, to the
--- filetype's REPL.
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

-- ============================================================================
-- Cells: blocks delimited by cell_marker lines
-- ============================================================================

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

  -- up/down stopped on the surrounding markers (or ran off the buffer):
  -- the cell is what lies strictly between them
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

--- Send the cell around the cursor to the filetype's REPL.
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

-- ============================================================================
-- Setup
-- ============================================================================

--- Bold red for error locations, taking the red from the active colorscheme.
local function define_error_highlight()
  local diag = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  vim.api.nvim_set_hl(0, "TarminalError", { fg = diag.fg or "Red", bold = true })
end

--- tarminal never creates keymaps: opts hold settings only. Map keys
--- yourself to :Tarminal subcommands or the functions in this module (see
--- the README's example setup; `FileType tarminal` fires for tarminal's own
--- terminal buffers, for buffer-local maps).
---@param opts tarminal.Config|nil merged over the defaults in M.config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  local group = vim.api.nvim_create_augroup("tarminal-highlight", { clear = true })

  define_error_highlight()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_error_highlight,
  })
end

return M
