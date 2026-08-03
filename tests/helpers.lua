-- shared fixtures for the spec files
local platform = require("tarminal.platform")

local M = {}

-- rows of the RUN banners printed in `term_buf` in buffer order
function M.banner_rows(term_buf)
  local rows = {}
  for row, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
    if l:match("^=====") and l:find("RUN", 1, true) then
      rows[#rows + 1] = row
    end
  end
  return rows
end

function M.output_count(term_buf, needle)
  local seen = 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
    if vim.startswith(vim.trim(l), needle) then
      seen = seen + 1
    end
  end
  return seen
end

-- wait until `n` banners are printed and the shell has the foreground
-- back so a follow-up run() is not refused by the busy guard
-- on slow CI the previous command still runs when two runs are issued
-- back to back
function M.wait_run_finished(term_buf, n, marker)
  local term_busy = platform.term_busy
  return vim.wait(8000, function()
    return #M.banner_rows(term_buf) >= n
      and not term_busy(term_buf)
      and (marker == nil or M.output_count(term_buf, marker) >= n)
  end, 50)
end

-- a "shell" that copies its stdin to `out` so the exact command tarminal
-- sends can be inspected
-- returns the path of the capture file
-- it ignores SIGINT like the real shell a run sends ^C to
---@param raw boolean|nil pass the control bytes through instead of letting the tty eat them
function M.stdin_capture_shell(raw)
  local out = vim.fn.tempname()
  local script = vim.fn.tempname() .. ".sh"
  local lines = { "trap '' INT", "exec cat > " .. out }
  if raw then
    table.insert(lines, 1, "stty raw -echo")
  end
  vim.fn.writefile(lines, script)
  return out, script
end

function M.wait_capture(out, needle)
  return vim.wait(8000, function()
    return vim.fn.filereadable(out) == 1 and table.concat(vim.fn.readfile(out), "\n"):find(needle, 1, true) ~= nil
  end, 50)
end

-- the most recent tarminal terminal buffer
function M.find_term_buf()
  local found
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "tarminal" then
      found = buf
    end
  end
  return found
end

-- reset the config before every spec and tear the terminals down after
function M.hooks()
  local tarminal = require("tarminal")

  before_each(function()
    tarminal.setup()
    vim.cmd("enew!")
  end)

  after_each(function()
    tarminal.setup()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
        -- force-deleting a terminal buffer while its job is alive with
        -- output in flight wedges the next terminal's refresh into a busy
        -- loop on nvim 0.12.4
        -- stop the job and wait for it to exit first
        local job = vim.b[buf].terminal_job_id
        if job then
          pcall(vim.fn.jobstop, job)
          pcall(vim.fn.jobwait, { job }, 1000)
        end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.cmd("silent! tabonly!")
  end)
end

return M
