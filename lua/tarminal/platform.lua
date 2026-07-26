--- Per-OS probes: shell cwd, busy state, and child detection.

local util = require("tarminal.util")

local uv = vim.uv or vim.loop

local M = {}

local SYSNAME = util.SYSNAME
local IS_BSD, IS_WINDOWS = util.IS_BSD, util.IS_WINDOWS
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

local PWSH = vim.fn.exepath("pwsh")
if PWSH == "" then
  PWSH = "powershell"
end

-- reads the shell's real cwd from its PEB (x64 offsets; 32-bit or elevated targets yield nil)
local WIN_CWD_PS = [==[
$ErrorActionPreference='SilentlyContinue'
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class TarminalCwd {
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int c, byte[] i, int l, out int r);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool b, int p);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, IntPtr n, out IntPtr r);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  static long ReadPtr(IntPtr h, long a) {
    byte[] b = new byte[8]; IntPtr r;
    return ReadProcessMemory(h, (IntPtr)a, b, (IntPtr)8, out r) ? BitConverter.ToInt64(b, 0) : 0;
  }
  public static string Get(int pid) {
    IntPtr h = OpenProcess(0x0410, false, pid);
    if (h == IntPtr.Zero) return null;
    try {
      byte[] pbi = new byte[48]; int ret;
      if (NtQueryInformationProcess(h, 0, pbi, 48, out ret) != 0) return null;
      long prm = ReadPtr(h, BitConverter.ToInt64(pbi, 8) + 0x20);
      if (prm == 0) return null;
      byte[] us = new byte[16]; IntPtr r;
      if (!ReadProcessMemory(h, (IntPtr)(prm + 0x38), us, (IntPtr)16, out r)) return null;
      ushort len = BitConverter.ToUInt16(us, 0);
      long buf = BitConverter.ToInt64(us, 8);
      if (len == 0 || len > 65534 || buf == 0) return null;
      byte[] pb = new byte[len];
      if (!ReadProcessMemory(h, (IntPtr)buf, pb, (IntPtr)len, out r)) return null;
      return System.Text.Encoding.Unicode.GetString(pb);
    } finally { CloseHandle(h); }
  }
}
"@
[TarminalCwd]::Get(%d)
]==]

local function windows_cwd_cmd(pid)
  return { PWSH, "-NoProfile", "-NonInteractive", "-Command", WIN_CWD_PS:format(pid) }
end

local function parse_windows_cwd(out)
  local path = vim.trim(out or "")
  if not (path:match("^%a:[/\\]") or path:match("^\\\\")) then
    return nil
  end
  if not path:match("^%a:[/\\]$") then
    path = path:gsub("[/\\]+$", "")
  end
  return path
end

-- probe pwsh is spawned by nvim, not the shell, so it never counts itself;
-- conhost is excluded in case one attaches under the shell
local function windows_has_child(pid)
  local out = vim.fn.system({
    PWSH,
    "-NoProfile",
    "-Command",
    "(Get-CimInstance Win32_Process -Filter 'ParentProcessId=" .. pid .. ' AND Name!="conhost.exe"\').Count',
  })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return (tonumber(vim.trim(out)) or 0) > 0
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
  if IS_WINDOWS then
    -- pwsh emits /C:/x; Git Bash/MSYS emit /c/x; Cygwin emits /cygdrive/c/x
    local drive = path:match("^/(%a:.*)$")
    if drive then
      return drive
    end
    local letter, rest = path:match("^/cygdrive/(%a)(/?.*)$")
    if not letter then
      letter, rest = path:match("^/(%a)(/.*)$")
    end
    if not letter then
      letter, rest = path:match("^/(%a)$"), "/"
    end
    if letter then
      return letter:upper() .. ":" .. (rest ~= "" and rest or "/")
    end
  end
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

-- probe is slow (pwsh startup + Add-Type), so: skipped while OSC 7 reports,
-- refreshed async with a longer TTL, and never blocks — callers get the
-- cached value (or nil, falling back to b:term_cwd) while a probe is in flight
local WIN_CWD_TTL = 5000

local function windows_cwd(buf, pid)
  if vim.b[buf].osc7_active or not vim.system then
    return nil
  end
  local slot = shell_cache[buf] or {}
  shell_cache[buf] = slot
  local c = slot.cwd
  if (c and uv.now() - c.t < WIN_CWD_TTL) or slot.cwd_probe then
    return c and c.v
  end
  slot.cwd_probe = true
  vim.system(windows_cwd_cmd(pid), { text = true, timeout = 8000 }, function(res)
    vim.schedule(function()
      slot.cwd_probe = nil
      if shell_cache[buf] == slot then
        slot.cwd = { t = uv.now(), v = parse_windows_cwd(res.stdout) }
      end
    end)
  end)
  return c and c.v
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
    elseif IS_WINDOWS then
      cwd = windows_cwd(buf, pid)
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
  elseif IS_WINDOWS then
    if fresh then
      return windows_has_child(pid)
    end
    return memo(buf, "busy", windows_has_child, pid)
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
  elseif IS_WINDOWS then
    return windows_has_child(pid)
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
M.windows_cwd_cmd = windows_cwd_cmd
M.parse_windows_cwd = parse_windows_cwd
M.windows_cwd = windows_cwd
M.osc7_cwd = osc7_cwd
M.prep_run_cache = prep_run_cache
M.clear_cache = clear_cache
M.term_cwd = term_cwd
M.term_busy = term_busy
M.shell_has_child = shell_has_child
M.wait_for_repl = wait_for_repl

return M
