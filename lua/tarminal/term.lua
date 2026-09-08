--- Terminal window/buffer management and channel plumbing

local config = require("tarminal.config")
local platform = require("tarminal.platform")
local state = require("tarminal.state")
local util = require("tarminal.util")

local M = {}

local function split_window()
  local pos = config.opts.split_position
  if pos == "auto" then
    pos = vim.o.splitbelow and "bottom" or "top"
  end
  local vertical = pos == "left" or pos == "right"
  local cmd = vertical and "vsplit" or "split"
  vim.cmd(((pos == "top" or pos == "left") and "topleft " or "botright ") .. cmd)
  local win = vim.api.nvim_get_current_win()
  if vertical then
    vim.api.nvim_win_set_width(win, config.opts.split_width)
    vim.wo.winfixwidth = true
  else
    vim.api.nvim_win_set_height(win, config.opts.split_height)
    vim.wo.winfixheight = true
  end
  return win
end

local titles = {}

-- sizes up to 1 are a fraction of the editor
local function float_config(title)
  local f = config.opts.float
  local lines = vim.o.lines - vim.o.cmdheight
  local function size(v, total)
    v = v <= 1 and math.floor(total * v) or v
    return math.max(math.min(v, total - 2), 1)
  end
  local width, height = size(f.width, vim.o.columns), size(f.height, lines)
  local cfg = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2) - 1,
    border = f.border,
  }
  if title and f.border and f.border ~= "none" and f.border ~= "" then
    cfg.title = " " .. title .. " "
    cfg.title_pos = "center"
  end
  return cfg
end

---@return integer win showing buf and current
local function open_window(buf)
  local layout = config.opts.layout
  local win
  if layout == "float" then
    win = vim.api.nvim_open_win(buf, true, float_config(titles[buf]))
  elseif type(layout) == "function" then
    win = layout(buf)
    vim.api.nvim_set_current_win(win)
  else
    win = split_window()
  end
  if vim.api.nvim_win_get_buf(win) ~= buf then
    vim.api.nvim_win_set_buf(win, buf)
  end
  return win
end

-- keep open floats centered when the editor resizes
local function refit_floats()
  if config.opts.layout ~= "float" then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if util.owns(buf) and vim.api.nvim_win_get_config(win).relative ~= "" then
      vim.api.nvim_win_set_config(win, float_config(titles[buf]))
    end
  end
end

local get_job_id = util.get_job_id

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
  return open_window(buf)
end

-- close the terminal's window
-- the last window can't close so blank it instead
local function close_window_for_buf(buf)
  local win = find_win_for_buf(buf)
  if win and not pcall(vim.api.nvim_win_close, win, false) then
    vim.api.nvim_win_call(win, function()
      vim.cmd("enew")
    end)
  end
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

-- the shell may be a spaced path with optional flags after it
-- keep the longest executable prefix as one argv entry
---@return string[]
local function shell_cmd(shell)
  local parts = vim.split(shell, "%s+", { trimempty = true })
  for i = #parts, 2, -1 do
    local exe = table.concat(parts, " ", 1, i)
    if vim.fn.executable(exe) == 1 then
      return vim.list_extend({ exe }, parts, i + 1)
    end
  end
  return parts
end

---@param name string buffer name like "tarminal://shell"
---@return integer|nil buf, integer|nil win
local function open_shell_term(name)
  local buf = vim.api.nvim_create_buf(true, false)
  titles[buf] = name:gsub("^tarminal://", "")
  local win = open_window(buf)
  local cmd = shell_cmd(config.opts.shell)
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
    local fail = "tarminal: could not start shell: " .. config.opts.shell
    vim.notify(msg or fail, vim.log.levels.ERROR)
    return nil
  end
  vim.b[buf].term_cwd = vim.fn.getcwd()

  for name, value in pairs(config.opts.win_opts) do
    vim.opt_local[name] = value
  end
  vim.bo[buf].filetype = "tarminal"
  if not config.opts.keep_term_name then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end

  return buf, win
end

local function term_send(buf, text)
  vim.fn.chansend(get_job_id(buf), text)
end

-- ^C leaves the prompt clear except for input the shell already read
local CANCEL_INPUT = "\003"
-- the tty flushes pending input with the signal so ours goes after
local CANCEL_DELAY = 50
-- end-of-line then line-kill clears that remainder in band so it cannot glue
-- itself onto the command
local KILL_LINE = "\005\021"

---@param cancel_pending boolean|nil drop typed-but-unsent input first
local function term_send_command(buf, cmd, cancel_pending)
  -- leading space keeps it out of shell history (ignorespace)
  local line = " " .. cmd .. "\n"
  if not cancel_pending then
    term_send(buf, line)
    return
  end
  term_send(buf, CANCEL_INPUT)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) and is_terminal_alive(buf) then
      term_send(buf, KILL_LINE .. line)
    end
  end, CANCEL_DELAY)
end

local sh_quote = util.sh_quote

local function term_cd(buf, dir)
  term_send_command(buf, "cd " .. sh_quote(dir))
  vim.b[buf].term_cwd = dir
end

-- clear scrollback (3J) home (H) then the screen (2J)
-- works in bash zsh and fish
local CLEAR_SEQ = "printf '\\033[3J\\033[H\\033[2J'"

local function clear_terminal(buf)
  term_send_command(buf, CLEAR_SEQ)
end

local OSC7_SETUP = {
  bash = [[__tarminal_osc7(){ printf '\033]7;file://%s%s\033\\' "${HOSTNAME:-}" "$PWD"; }; case ";${PROMPT_COMMAND};" in *__tarminal_osc7*) ;; *) PROMPT_COMMAND="__tarminal_osc7${PROMPT_COMMAND:+;$PROMPT_COMMAND}";; esac]],
  zsh = [[autoload -Uz add-zsh-hook 2>/dev/null; __tarminal_osc7(){ printf '\033]7;file://%s%s\033\\' "${HOST:-}" "$PWD"; }; add-zsh-hook precmd __tarminal_osc7 2>/dev/null || precmd_functions+=(__tarminal_osc7)]],
  fish = [[function __tarminal_osc7 --on-variable PWD; printf '\033]7;file://%s%s\033\\' "$hostname" "$PWD"; end; __tarminal_osc7]],
}

local function osc7_snippet(cmd)
  local exe = shell_cmd(cmd)[1] or ""
  local name = vim.fn.fnamemodify(exe, ":t"):lower()
  return OSC7_SETUP[name]
end

local function enable_shell_integration(buf)
  -- the OS probe already answers and costs nothing at the prompt
  if not config.opts.shell_integration or platform.has_cwd_probe() then
    return
  end
  local snippet = osc7_snippet(config.opts.shell)
  if snippet then
    term_send_command(buf, snippet)
    -- hide the setup command + its output so the shell starts clean
    clear_terminal(buf)
  end
end

---@param follow tarminal.Follow
---@param start_at_top boolean|nil
local function focus_after_send(term_win, code_win, follow, start_at_top)
  state._last_code_win = code_win
  vim.api.nvim_win_call(term_win, function()
    vim.cmd(start_at_top and "normal! Gzt" or "normal! G")
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

M.shell_cmd = shell_cmd
M.float_config = float_config
M.refit_floats = refit_floats
M.find_win_for_buf = find_win_for_buf
M.ensure_window_for_buf = ensure_window_for_buf
M.close_window_for_buf = close_window_for_buf
M.find_live_terminal = find_live_terminal
M.open_shell_term = open_shell_term
M.term_send = term_send
M.term_send_command = term_send_command
M.term_cd = term_cd
M.CLEAR_SEQ = CLEAR_SEQ
M.clear_terminal = clear_terminal
M.OSC7_SETUP = OSC7_SETUP
M.osc7_snippet = osc7_snippet
M.enable_shell_integration = enable_shell_integration
M.focus_after_send = focus_after_send

return M
