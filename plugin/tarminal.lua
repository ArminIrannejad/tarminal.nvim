if vim.g.loaded_tarminal then
  return
end
vim.g.loaded_tarminal = true

if vim.fn.has("nvim-0.9") == 0 then
  vim.notify("tarminal.nvim requires Neovim >= 0.9", vim.log.levels.ERROR)
  return
end

local subcommands = {
  "toggle",
  "run",
  "exec",
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
  require("tarminal")[sub](cmd)
end, {
  nargs = "*",
  range = true,
  complete = function(arglead, cmdline, cursorpos)
    local before = cmdline:sub(1, cursorpos or #cmdline)
    local rest = before:match("^%s*Tarminal!?%s+(.*)$")
    if not rest then
      return {}
    end
    local sub = rest:match("^(%S+)%s+")
    if not sub then
      return vim.tbl_filter(function(s)
        return vim.startswith(s, arglead)
      end, subcommands)
    end
    -- paths only: $PATH would bury the useful matches under hundreds of names
    if sub == "exec" then
      return vim.fn.getcompletion(arglead, "file")
    end
    return {}
  end,
  desc = "Open Tarminal (default: toggle) — :Tarminal <Tab> for all actions",
})
