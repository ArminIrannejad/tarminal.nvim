describe("tarminal health", function()
  require("tarminal")

  local function run_checkhealth()
    vim.cmd("checkhealth tarminal")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    vim.cmd("bwipeout!")
    return table.concat(lines, "\n")
  end

  it("reports every section without erroring", function()
    local out = run_checkhealth()
    for _, section in ipairs({ "Neovim", "Process probes", "Shell", "Configured commands" }) do
      assert.is_truthy(out:find(section, 1, true), "missing section: " .. section)
    end
    assert.is_nil(out:match("ERROR"), out)
  end)

  it("flags a shell that does not exist", function()
    require("tarminal").setup({ shell = "/definitely/missing-shell" })
    local out = run_checkhealth()
    require("tarminal").setup()
    assert.is_truthy(out:find("shell is not executable", 1, true), out)
  end)
end)
