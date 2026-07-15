describe("tarminal", function()
  it("can be required", function()
    require("tarminal")
  end)

  it("setup merges user options over defaults", function()
    local tarminal = require("tarminal")
    tarminal.setup({ split_height = 20, runners = { rust = "cargo run" } })
    assert.equals(20, tarminal.config.split_height)
    assert.equals("cargo run", tarminal.config.runners.rust)
    -- untouched defaults survive the merge
    assert.equals("python", tarminal.config.runners.python)
    assert.equals("ipython", tarminal.config.repls.python)
  end)

  local function has_normal_map(desc)
    for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
      if map.desc == desc then
        return true
      end
    end
    return false
  end

  it("setup creates no keymaps by default", function()
    local tarminal = require("tarminal")
    tarminal.setup()
    assert.is_false(has_normal_map("Toggle shell terminal"))
  end)

  it("setup maps only the configured keys", function()
    local tarminal = require("tarminal")
    tarminal.setup({ keymaps = { toggle = "<leader>ts" } })
    assert.is_true(has_normal_map("Toggle shell terminal"))
    assert.is_false(has_normal_map("Run current file in terminal"))
  end)

  it("toggle opens and closes the shell terminal split", function()
    local tarminal = require("tarminal")
    tarminal.setup()
    local before = #vim.api.nvim_list_wins()
    tarminal.toggle()
    assert.equals(before + 1, #vim.api.nvim_list_wins())
    assert.equals("terminal", vim.bo[vim.api.nvim_get_current_buf()].buftype)
    tarminal.toggle()
    assert.equals(before, #vim.api.nvim_list_wins())
  end)
end)
