--- Per-OS probes for shell cwd busy state and child detection

local util = require("tarminal.util")

local uv = vim.uv

local M = {}

local SYSNAME = util.SYSNAME
local IS_BSD = util.IS_BSD
local get_job_id = util.get_job_id

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

local function linux_cwd(pid)
  return uv.fs_readlink("/proc/" .. pid .. "/cwd")
end

local function linux_busy(pid)
  local f = io.open("/proc/" .. pid .. "/stat", "r")
  if not f then
    return nil
  end
  local stat = f:read("*a") or ""
  f:close()
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

local function linux_has_child(pid)
  local f = io.open("/proc/" .. pid .. "/task/" .. pid .. "/children", "r")
  if not f then
    return nil
  end
  local kids = f:read("*a") or ""
  f:close()
  return vim.trim(kids) ~= ""
end

local function pgrep_has_child(pid)
  local out = vim.fn.system({ "pgrep", "-P", tostring(pid) })
  return vim.v.shell_error == 0 and vim.trim(out) ~= ""
end

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

local LSOF = vim.fn.exepath("lsof")
if LSOF == "" then
  LSOF = "/usr/sbin/lsof"
end

local function parse_lsof_cwd(out)
  return out:match("\nn([^\n]+)") or out:match("^n([^\n]+)")
end

local function darwin_cwd(pid)
  local out = vim.fn.system({ LSOF, "-a", "-p", tostring(pid), "-d", "cwd", "-Fn" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return parse_lsof_cwd(out)
end

local function parse_procstat_cwd(out)
  for line in out:gmatch("[^\n]+") do
    if line:match("^%s*%d+%s+%S+%s+cwd%s") then
      local p = line:match("(/.*)$")
      if p then
        return vim.trim(p)
      end
    end
  end
  return nil
end

local function bsd_cwd(pid)
  if SYSNAME == "NetBSD" then
    return uv.fs_readlink("/proc/" .. pid .. "/cwd")
  end
  if SYSNAME ~= "FreeBSD" then
    return nil
  end
  local out = vim.fn.system({ "procstat", "-f", tostring(pid) })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return parse_procstat_cwd(out)
end

---@return string|nil
local function osc7_cwd(seq)
  local path = seq:match("]7;file://[^/]*(/[^\007\027]*)")
  if not path then
    return nil
  end
  path = path:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  return path
end

local SHELL_TTL = 1000
local shell_cache = {}

local function memo(buf, kind, provider, pid)
  local slot = shell_cache[buf] or {}
  shell_cache[buf] = slot
  local c = slot[kind]
  local now = uv.now()
  if c and now - c.t < SHELL_TTL then
    return c.v
  end
  local v = provider(pid)
  slot[kind] = { t = now, v = v }
  return v
end

local function prep_run_cache(buf, dir)
  local slot = shell_cache[buf] or {}
  shell_cache[buf] = slot
  slot.cwd = { t = uv.now(), v = dir }
  slot.busy = nil
end

---@return string|nil
local function term_cwd(buf)
  local pid = term_pid(buf)
  if pid then
    local cwd
    if SYSNAME == "Linux" then
      cwd = linux_cwd(pid)
    elseif SYSNAME == "Darwin" then
      cwd = memo(buf, "cwd", darwin_cwd, pid)
    elseif IS_BSD then
      cwd = memo(buf, "cwd", bsd_cwd, pid)
    end
    if cwd then
      return cwd
    end
  end
  return vim.b[buf].term_cwd
end

---@return boolean|nil busy nil when undeterminable
local function term_busy(buf, fresh)
  local pid = term_pid(buf)
  if not pid then
    return nil
  end
  if SYSNAME == "Linux" then
    return linux_busy(pid)
  elseif SYSNAME == "Darwin" or IS_BSD then
    if fresh then
      return ps_busy(pid)
    end
    return memo(buf, "busy", ps_busy, pid)
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

---@return boolean
local function wait_for_repl(buf)
  if shell_has_child(buf) == nil then
    return true
  end
  return vim.wait(2000, function()
    return shell_has_child(buf)
  end, 20) and shell_has_child(buf) == true
end

local function clear_cache(buf)
  shell_cache[buf] = nil
end

M.parse_lsof_cwd = parse_lsof_cwd
M.parse_procstat_cwd = parse_procstat_cwd
M.osc7_cwd = osc7_cwd
M.prep_run_cache = prep_run_cache
M.clear_cache = clear_cache
M.term_cwd = term_cwd
M.term_busy = term_busy
M.shell_has_child = shell_has_child
M.wait_for_repl = wait_for_repl

return M
