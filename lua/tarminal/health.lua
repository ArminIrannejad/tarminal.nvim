--- :checkhealth tarminal — verify the per-OS probes and the configured commands.

local config = require("tarminal.config")
local term = require("tarminal.term")
local util = require("tarminal.util")

local start, ok, info, warn, err = vim.health.start, vim.health.ok, vim.health.info, vim.health.warn, vim.health.error

local uv = vim.uv

local M = {}

local function check_version()
  start("Neovim")
  if vim.fn.has("nvim-0.10") == 0 then
    err("Neovim 0.10 or newer is required")
    return
  end
  ok(vim.fn.matchstr(vim.fn.execute("version"), "NVIM v\\zs[^\n]*"))
end

local function readable(path)
  local f = io.open(path, "r")
  if not f then
    return false
  end
  f:close()
  return true
end

-- the three probes back cwd resolution, the busy guard, and REPL startup
local function check_probes()
  start("Process probes")
  local sysname = util.SYSNAME
  local pid = uv.os_getpid()

  if sysname == "Linux" then
    info("Linux (incl. WSL): reading /proc")
    if uv.fs_readlink("/proc/" .. pid .. "/cwd") then
      ok("cwd: /proc/<pid>/cwd")
    else
      warn("cwd: /proc/<pid>/cwd unreadable", { "Relative error paths fall back to Neovim's cwd." })
    end
    if readable("/proc/" .. pid .. "/stat") then
      ok("busy: /proc/<pid>/stat")
    else
      warn("busy: /proc/<pid>/stat unreadable", { "Runs will not be blocked while the terminal is busy." })
    end
    if readable("/proc/" .. pid .. "/task/" .. pid .. "/children") then
      ok("child: /proc/<pid>/task/<pid>/children")
    else
      warn("child: /proc children file missing", {
        "Kernel built without CONFIG_PROC_CHILDREN; tarminal cannot tell when a REPL is up.",
      })
    end
    return
  end

  if sysname == "Darwin" then
    info("macOS: shelling out to lsof/ps/pgrep")
    local lsof = vim.fn.exepath("lsof")
    if lsof == "" and vim.fn.executable("/usr/sbin/lsof") == 1 then
      lsof = "/usr/sbin/lsof"
    end
    if lsof ~= "" then
      ok("cwd: " .. lsof)
    else
      warn("cwd: lsof not found", { "Install lsof, or rely on shell_integration for cwd tracking." })
    end
  elseif util.IS_BSD then
    if sysname == "NetBSD" then
      info("NetBSD: reading /proc")
      if uv.fs_readlink("/proc/" .. pid .. "/cwd") then
        ok("cwd: /proc/<pid>/cwd")
      else
        warn("cwd: /proc/<pid>/cwd unreadable", { "Mount procfs, or rely on shell_integration." })
      end
    elseif sysname == "FreeBSD" then
      info("FreeBSD: shelling out to procstat/ps/pgrep")
      if vim.fn.executable("procstat") == 1 then
        ok("cwd: procstat")
      else
        warn("cwd: procstat not found", { "Rely on shell_integration for cwd tracking." })
      end
    else
      info(sysname .. ": no cwd probe; shell_integration is the only source")
    end
  else
    warn(sysname .. " is not a supported platform", {
      "tarminal supports Linux (incl. WSL), macOS, and BSD.",
      "Runs still work; cwd tracking and the busy guard do not.",
    })
    return
  end

  for _, probe in ipairs({ { "busy", "ps" }, { "child", "pgrep" } }) do
    if vim.fn.executable(probe[2]) == 1 then
      ok(probe[1] .. ": " .. probe[2])
    else
      warn(probe[1] .. ": " .. probe[2] .. " not found")
    end
  end
end

local function check_shell()
  start("Shell")
  local shell = config.opts.shell
  local argv = term.shell_cmd(shell)
  local exe = argv[1] or ""

  if exe == "" or vim.fn.executable(exe) == 0 then
    err(("shell is not executable: %s"):format(shell), { "Set `shell` to a shell that exists." })
    return
  end
  ok("shell: " .. shell)

  if not config.opts.shell_integration then
    info("shell_integration is off")
    return
  end
  if term.osc7_snippet(shell) then
    ok(("shell_integration: OSC 7 snippet for %s"):format(vim.fn.fnamemodify(exe, ":t")))
  else
    info(("shell_integration: no snippet for %s (only bash, zsh, fish)"):format(vim.fn.fnamemodify(exe, ":t")), {
      "Falls back to the per-OS cwd probe. See |tarminal-shell-integration|.",
    })
  end
end

---@return string[] filetypes whose command's first word is not executable
local function missing(specs)
  local out = {}
  for ft, spec in pairs(specs) do
    local cmd = type(spec) == "table" and spec.cmd or spec
    local exe = type(cmd) == "string" and cmd:match("%S+")
    if exe and vim.fn.executable(exe) == 0 then
      out[#out + 1] = ("%s (%s)"):format(ft, exe)
    end
  end
  table.sort(out)
  return out
end

local function check_commands()
  start("Configured commands")
  for label, specs in pairs({ runners = config.opts.runners, repls = config.opts.repls }) do
    local gone = missing(specs)
    if #gone == 0 then
      ok(("all %s are installed"):format(label))
    else
      info(("%s not installed: %s"):format(label, table.concat(gone, ", ")), {
        "Only matters for those filetypes; override them in setup() or install the tool.",
      })
    end
  end

  if config.opts.time_runs and vim.fn.executable("time") == 0 then
    info("time_runs is on but no `time` binary is installed; runs will not be timed")
  end
end

function M.check()
  check_version()
  check_probes()
  check_shell()
  check_commands()
end

return M
