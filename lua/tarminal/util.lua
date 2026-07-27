--- Shared helpers and platform constants.

local uv = vim.uv

local M = {}

M.SYSNAME = (uv.os_uname() or {}).sysname or ""
M.IS_BSD = M.SYSNAME == "FreeBSD" or M.SYSNAME == "OpenBSD" or M.SYSNAME == "NetBSD"

function M.get_job_id(buf)
  return vim.b[buf].terminal_job_id
end

-- POSIX quoting for the spawned shell, regardless of &shell
function M.sh_quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

return M
