-- Entry point loaded automatically by Neovim at startup.
-- Keep this file light: only guards and commands.
-- The implementation lives in lua/tarminal/ and is loaded lazily via require.

if vim.g.loaded_tarminal then
  return
end
vim.g.loaded_tarminal = true

if vim.fn.has("nvim-0.9") == 0 then
  vim.notify("tarminal.nvim requires Neovim >= 0.9", vim.log.levels.ERROR)
  return
end

-- Every plugin action, so users can drive tarminal entirely through
-- :Tarminal without any keymaps configured.
local subcommands = {
  "toggle",
  "run",
  "send_cell",
  "send_selection",
  "jump_to_error",
  "next_error",
  "prev_error",
  "errors_to_quickfix",
}

vim.api.nvim_create_user_command("Tarminal", function(cmd)
  local sub = cmd.fargs[1] or "toggle"
  if not vim.tbl_contains(subcommands, sub) then
    vim.notify("Tarminal: unknown subcommand: " .. sub, vim.log.levels.ERROR)
    return
  end
  require("tarminal")[sub]()
end, {
  nargs = "?",
  range = true,
  complete = function(arglead)
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arglead)
    end, subcommands)
  end,
  desc = "Open Tarminal (default: toggle) — :Tarminal <Tab> for all actions",
})
