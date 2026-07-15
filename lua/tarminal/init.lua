---@class Tarminal
local M = {}

---@class TarminalConfig
local defaults = {
  -- Add your default options here, e.g.:
  -- direction = "float",
}

---@type TarminalConfig
M.options = {}

---Setup the plugin. Called by the user, optionally with overrides.
---@param opts? TarminalConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, defaults, opts or {})
end

---Example entry point, wired to the :Tarminal command.
function M.open()
  vim.notify("tarminal.nvim: hello!", vim.log.levels.INFO)
end

return M
