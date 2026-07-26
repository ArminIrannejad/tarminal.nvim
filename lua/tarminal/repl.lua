--- REPL lifecycle, visual-selection capture, and cell sending.

local config = require("tarminal.config")
local platform = require("tarminal.platform")
local term = require("tarminal.term")

local M = {}

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

M.get_visual_selection = get_visual_selection
M.get_line_range = get_line_range
M.repl_spec = repl_spec
M.send_to_repl = send_to_repl
M.get_current_cell_text = get_current_cell_text

return M
