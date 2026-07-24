-- Platform-portable unit tests: the OS-specific parsers and shell wiring, fed
-- fixed sample input so they assert deterministically on every OS (Linux,
-- macOS, BSD, Windows). The behavioral suite in tarminal_spec.lua spawns real
-- POSIX shells and is not meant to run on Windows.
describe("tarminal platform", function()
  local tarminal

  -- Same upvalue reach-in as tarminal_spec: descend through function-valued
  -- upvalues to find a module local captured by a public entry point.
  local function find_upvalue(fn, wanted, seen)
    if seen[fn] then
      return nil
    end
    seen[fn] = true
    local fns = {}
    for i = 1, 40 do
      local name, value = debug.getupvalue(fn, i)
      if not name then
        break
      end
      if name == wanted then
        return value
      end
      if type(value) == "function" then
        fns[#fns + 1] = value
      end
    end
    for _, f in ipairs(fns) do
      local value = find_upvalue(f, wanted, seen)
      if value ~= nil then
        return value
      end
    end
  end

  local function get_upvalue(fn, wanted)
    local value = find_upvalue(fn, wanted, {})
    if value == nil then
      error("missing upvalue: " .. wanted)
    end
    return value
  end

  local function sysname()
    return (vim.uv or vim.loop).os_uname().sysname
  end

  before_each(function()
    tarminal = require("tarminal")
    tarminal.setup()
  end)

  it("parses the cwd out of an OSC 7 report", function()
    local osc7_cwd = get_upvalue(tarminal.setup, "osc7_cwd")
    local ESC, BEL = "\027", "\007"

    -- ESC ] 7 ; file://host/path ST(=ESC \)
    assert.equals("/tmp", osc7_cwd(ESC .. "]7;file://myhost/tmp" .. ESC .. "\\"))
    -- BEL terminator, and percent-encoded bytes must be decoded
    assert.equals("/home/a b/p", osc7_cwd(ESC .. "]7;file://h/home/a%20b/p" .. BEL))
    -- empty host is allowed (file:///path)
    assert.equals("/no/host", osc7_cwd("]7;file:///no/host" .. BEL))
    -- an unrelated OSC (window title) is not a cwd report
    assert.is_nil(osc7_cwd(ESC .. "]0;a title" .. BEL))
  end)

  it("strips the drive-letter slash from OSC 7 only on Windows", function()
    local osc7_cwd = get_upvalue(tarminal.setup, "osc7_cwd")
    local got = osc7_cwd("]7;file:///C:/Users/me\007")
    if sysname() == "Windows_NT" then
      assert.equals("C:/Users/me", got)
    else
      assert.equals("/C:/Users/me", got)
    end
  end)

  it("extracts the cwd row from procstat -f output", function()
    local parse = get_upvalue(tarminal.jump_to_error, "parse_procstat_cwd")
    local out = table.concat({
      "  PID COMM               FD T V FLAGS    REF  OFFSET PRO NAME",
      " 1234 bash               rt v r r------   1       0   -  -",
      " 1234 bash              cwd v d -------   -       -   -  /home/user/project",
      " 1234 bash                0 t c rw------   3       0   -  /dev/pts/1",
    }, "\n")
    assert.equals("/home/user/project", parse(out))
    -- no cwd row -> nil so term_cwd falls back to the recorded value
    assert.is_nil(parse(" 1234 bash 0 t c rw------ 3 0 - /dev/pts/1"))
  end)

  it("has no cheap native cwd probe on Windows (falls back to OSC 7)", function()
    local windows_cwd = get_upvalue(tarminal.jump_to_error, "windows_cwd")
    assert.is_nil(windows_cwd(1234))
  end)

  it("selects an OSC 7 shell-integration snippet by shell basename", function()
    local osc7_snippet = get_upvalue(tarminal.toggle, "osc7_snippet")

    assert.is_string(osc7_snippet("/bin/bash"))
    assert.is_string(osc7_snippet("zsh"))
    assert.is_string(osc7_snippet("/usr/bin/zsh -l")) -- args ignored
    assert.is_string(osc7_snippet("pwsh"))
    assert.is_string(osc7_snippet("pwsh.exe"))
    assert.is_string(osc7_snippet("C:\\PowerShell\\pwsh.exe")) -- backslashes + .exe
    -- fish emits OSC 7 itself; unknown shells are left alone
    assert.is_nil(osc7_snippet("/usr/bin/fish"))
    assert.is_nil(osc7_snippet("cmd.exe"))

    -- every wired snippet must emit an OSC 7 file:// sequence
    local OSC7_SETUP = get_upvalue(tarminal.toggle, "OSC7_SETUP")
    for name, snippet in pairs(OSC7_SETUP) do
      assert.is_truthy(snippet:find("]7;file://", 1, true), name .. " snippet missing OSC 7")
    end
  end)

  it("respects shell_integration = false", function()
    tarminal.setup({ shell_integration = false })
    assert.is_false(tarminal.config.shell_integration)
  end)
end)
