local helpers = require("tests.helpers")

describe("tarminal config", function()
  local tarminal = require("tarminal")

  helpers.hooks()

  it("can be required", function()
    assert.is_table(tarminal)
  end)

  it("setup merges user options over defaults", function()
    tarminal.setup({ split_height = 20, runners = { rust = "cargo run" } })
    assert.equals(20, tarminal.config.split_height)
    assert.equals("cargo run", tarminal.config.runners.rust)
    -- untouched defaults survive the merge
    assert.equals("python", tarminal.config.runners.python)
    assert.equals("node", tarminal.config.runners.javascript)
    assert.equals("ipython", tarminal.config.repls.python)
  end)

  it("setup creates no keymaps", function()
    tarminal.setup()
    for _, mode in ipairs({ "n", "x", "t" }) do
      for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
        assert.is_falsy((map.desc or ""):lower():find("tarminal"))
      end
    end
  end)

  it("defaults a run to a cleared screen with a banner and the focus", function()
    tarminal.setup()
    assert.equals("focus", tarminal.config.follow_run)
    assert.is_true(tarminal.config.banner)
    assert.is_true(tarminal.config.clear_run)
    assert.is_false(tarminal.config.time_runs)
  end)

  it("setup resets previous options", function()
    tarminal.setup({ split_height = 20 })
    tarminal.setup()
    assert.equals(12, tarminal.config.split_height)
  end)
end)
