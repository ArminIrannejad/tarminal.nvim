-- the suite runs with --noplugin so source the command definition by hand
describe("the :Tarminal command", function()
  vim.cmd("runtime plugin/tarminal.lua")

  local function complete(cmdline)
    return vim.fn.getcompletion(cmdline, "cmdline")
  end

  local function has(list, want)
    return vim.tbl_contains(list, want)
  end

  it("completes subcommands and filters them by prefix", function()
    local all = complete("Tarminal ")
    for _, sub in ipairs({ "toggle", "run", "exec", "send_cell", "errors_to_quickfix" }) do
      assert.is_true(has(all, sub), "missing subcommand: " .. sub)
    end
    assert.same({ "exec", "errors_to_quickfix" }, complete("Tarminal e"))
  end)

  it("completes exec arguments as paths, never as $PATH commands", function()
    -- "l" matches lua/ here and hundreds of binaries on $PATH so only the path wins
    local out = complete("Tarminal exec l")
    assert.is_true(has(out, "lua/"), vim.inspect(out))
    for _, cmd in ipairs({ "ls", "less", "ln" }) do
      assert.is_false(has(out, cmd), "leaked a $PATH command: " .. cmd)
    end
  end)

  it("completes nested paths and later exec arguments", function()
    assert.is_true(has(complete("Tarminal exec lua/tarminal/co"), "lua/tarminal/config.lua"))
    assert.is_true(has(complete("Tarminal exec ls doc/"), "doc/tarminal.txt"))
  end)

  it("offers nothing for subcommands that take no arguments", function()
    assert.same({}, complete("Tarminal run "))
    assert.same({}, complete("Tarminal toggle "))
  end)
end)
