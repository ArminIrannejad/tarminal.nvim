-- Entry point loaded automatically by Neovim at startup.
-- Keep this file light: only guards, commands, and autocmds.
-- Heavy work belongs in lua/tarminal/ so it is loaded lazily via require.

if vim.g.loaded_tarminal then
  return
end
vim.g.loaded_tarminal = true

if vim.fn.has("nvim-0.9") == 0 then
  vim.notify("tarminal.nvim requires Neovim >= 0.9", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Tarminal", function()
  require("tarminal").open()
end, { desc = "Open tarminal" })
