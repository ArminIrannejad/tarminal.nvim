-- Runs in its own nvim, so `require` here is the first load of the module.
describe("tarminal without setup()", function()
  require("tarminal")

  it("defines the error highlights", function()
    for _, name in ipairs({ "TarminalError", "TarminalWarning" }) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      assert.is_truthy(hl.fg, name .. " has no foreground")
    end
  end)

  it("registers the cwd-tracking and cache autocmds", function()
    local events = {}
    for _, au in ipairs(vim.api.nvim_get_autocmds({ group = "tarminal-highlight" })) do
      events[au.event] = true
    end
    assert.is_true(events.ColorScheme)
    assert.is_true(events.BufWipeout)
    assert.is_true(events.TermRequest)
  end)

  it("serves the defaults through the config facade", function()
    assert.equals(12, require("tarminal").config.split_height)
  end)
end)
