describe("tarminal platform", function()
  local tarminal

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

    assert.equals("/tmp", osc7_cwd(ESC .. "]7;file://myhost/tmp" .. ESC .. "\\"))
    assert.equals("/home/a b/p", osc7_cwd(ESC .. "]7;file://h/home/a%20b/p" .. BEL))
    assert.equals("/no/host", osc7_cwd("]7;file:///no/host" .. BEL))
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
    assert.is_nil(parse(" 1234 bash 0 t c rw------ 3 0 - /dev/pts/1"))
  end)

  it("keeps the drive letter in a Windows diagnostic path", function()
    if sysname() ~= "Windows_NT" then
      return
    end
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main(){}" }, file)
    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    local parsed, line, col = parse(file .. ":10:2: error", vim.api.nvim_get_current_buf())
    vim.fn.delete(file)
    assert.equals(file, parsed)
    assert.equals(10, line)
    assert.equals(2, col)
  end)

  it("has no cheap native cwd probe on Windows", function()
    local windows_cwd = get_upvalue(tarminal.jump_to_error, "windows_cwd")
    assert.is_nil(windows_cwd(1234))
  end)

  it("selects an OSC 7 shell-integration snippet by shell basename", function()
    local osc7_snippet = get_upvalue(tarminal.toggle, "osc7_snippet")

    assert.is_string(osc7_snippet("/bin/bash"))
    assert.is_string(osc7_snippet("zsh"))
    assert.is_string(osc7_snippet("/usr/bin/zsh -l"))
    assert.is_string(osc7_snippet("pwsh"))
    assert.is_string(osc7_snippet("pwsh.exe"))
    assert.is_string(osc7_snippet("C:\\PowerShell\\pwsh.exe"))
    assert.is_nil(osc7_snippet("/usr/bin/fish"))
    assert.is_nil(osc7_snippet("cmd.exe"))

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
