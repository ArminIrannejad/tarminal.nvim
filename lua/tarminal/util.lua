--- Shared helpers and platform constants.

local uv = vim.uv or vim.loop

local M = {}

M.SYSNAME = (uv.os_uname() or {}).sysname or ""
M.IS_BSD = M.SYSNAME == "FreeBSD" or M.SYSNAME == "OpenBSD" or M.SYSNAME == "NetBSD"
M.IS_WINDOWS = M.SYSNAME == "Windows_NT"
M.SEP = M.IS_WINDOWS and "\\" or "/"

function M.get_job_id(buf)
  return vim.b[buf].terminal_job_id
end

-- POSIX quoting regardless of &shell (shellescape emits cmd.exe quoting on Windows)
function M.sh_quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

return M
