describe("tarminal platform", function()
  local tarminal
  local platform = require("tarminal.platform")
  local term = require("tarminal.term")

  before_each(function()
    tarminal = require("tarminal")
    tarminal.setup()
  end)

  it("parses the cwd out of an OSC 7 report", function()
    local osc7_cwd = platform.osc7_cwd
    local ESC, BEL = "\027", "\007"

    assert.equals("/tmp", osc7_cwd(ESC .. "]7;file://myhost/tmp" .. ESC .. "\\"))
    assert.equals("/home/a b/p", osc7_cwd(ESC .. "]7;file://h/home/a%20b/p" .. BEL))
    assert.equals("/no/host", osc7_cwd("]7;file:///no/host" .. BEL))
    assert.is_nil(osc7_cwd(ESC .. "]0;a title" .. BEL))
  end)

  it("extracts the cwd row from procstat -f output", function()
    local parse = platform.parse_procstat_cwd
    local out = table.concat({
      "  PID COMM               FD T V FLAGS    REF  OFFSET PRO NAME",
      " 1234 bash               rt v r r------   1       0   -  -",
      " 1234 bash              cwd v d -------   -       -   -  /home/user/project",
      " 1234 bash                0 t c rw------   3       0   -  /dev/pts/1",
    }, "\n")
    assert.equals("/home/user/project", parse(out))
    assert.is_nil(parse(" 1234 bash 0 t c rw------ 3 0 - /dev/pts/1"))
  end)

  it("selects an OSC 7 shell-integration snippet by shell basename", function()
    local osc7_snippet = term.osc7_snippet

    assert.is_string(osc7_snippet("/bin/bash"))
    assert.is_string(osc7_snippet("zsh"))
    assert.is_string(osc7_snippet("/usr/bin/zsh -l"))
    assert.is_string(osc7_snippet("/usr/bin/fish"))
    assert.is_nil(osc7_snippet("/bin/tcsh"))

    local OSC7_SETUP = term.OSC7_SETUP
    for name, snippet in pairs(OSC7_SETUP) do
      assert.is_truthy(snippet:find("]7;file://", 1, true), name .. " snippet missing OSC 7")
    end
  end)

  it("respects shell_integration = false", function()
    tarminal.setup({ shell_integration = false })
    assert.is_false(tarminal.config.shell_integration)
  end)
end)
