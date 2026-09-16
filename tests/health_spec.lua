describe("tarminal health", function()
  require("tarminal")

  local function run_checkhealth()
    vim.cmd("checkhealth tarminal")
    vim.wait(5000, function()
      return vim.bo.filetype == "checkhealth"
    end, 20)
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

  it("flags a project runner whose tool is not installed", function()
    require("tarminal").setup({
      project_runners = {
        { marker = "x.toml", cmd = "definitely-missing-tool run" },
        {
          marker = "y.toml",
          cmd = function()
            return "another-missing-tool go"
          end,
        },
      },
    })
    local out = run_checkhealth()
    require("tarminal").setup()
    assert.is_truthy(out:find("x.toml (definitely-missing-tool)", 1, true), out)
    assert.is_truthy(out:find("y.toml (another-missing-tool)", 1, true), out)
  end)

  it("flags a shell that does not exist", function()
    require("tarminal").setup({ shell = "/definitely/missing-shell" })
    local out = run_checkhealth()
    require("tarminal").setup()
    assert.is_truthy(out:find("shell is not executable", 1, true), out)
  end)
end)
