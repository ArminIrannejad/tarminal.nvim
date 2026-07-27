--- tarminal.nvim — terminal runner / REPL integration.

local config = require("tarminal.config")
local errors = require("tarminal.errors")
local platform = require("tarminal.platform")
local repl = require("tarminal.repl")
local run = require("tarminal.run")
local state = require("tarminal.state")

local M = {}

M.toggle = run.toggle
M.run = run.run
M.exec = run.exec
M.send_selection = repl.send_selection
M.send_cell = repl.send_cell
M.jump_to_error = errors.jump_to_error
M.next_error = errors.next_error
M.prev_error = errors.prev_error
M.errors_to_quickfix = errors.errors_to_quickfix

-- runs on require, so highlights and cwd tracking work without setup()
local function register()
  local group = vim.api.nvim_create_augroup("tarminal-highlight", { clear = true })

  errors.define_highlight()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = errors.define_highlight,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      platform.clear_cache(ev.buf)
    end,
  })
  pcall(vim.api.nvim_create_autocmd, "TermRequest", {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].filetype ~= "tarminal" then
        return
      end
      local seq = type(ev.data) == "table" and ev.data.sequence or ev.data
      if type(seq) ~= "string" then
        return
      end
      local cwd = platform.osc7_cwd(seq)
      if cwd and cwd ~= "" then
        vim.b[ev.buf].term_cwd = cwd
        vim.b[ev.buf].osc7_active = true
      end
    end,
  })
end

register()

---@param opts tarminal.Config|nil merged over the defaults; optional
function M.setup(opts)
  config.setup(opts)
end

setmetatable(M, {
  __index = function(_, k)
    if k == "config" then
      return config.opts
    end
    return state[k]
  end,
})

return M
