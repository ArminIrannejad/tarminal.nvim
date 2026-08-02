-- minimal init used by the test runner (see Makefile)
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = root .. "/.deps/plenary.nvim"

-- cut the user's own plugin directories out of both paths
-- a tarminal under site/pack would otherwise win the `require` and the
-- suite would silently test that copy
-- a site-installed treesitter parser built for a different ABI breaks
-- every ftplugin under an older Neovim
-- everything the interpreter ships with stays on the runtimepath
local mine = { vim.fn.stdpath("data"), vim.fn.stdpath("config") }
vim.opt.packpath = {}
vim.opt.runtimepath = vim.tbl_filter(function(path)
  return not vim.startswith(path, mine[1]) and not vim.startswith(path, mine[2])
end, vim.api.nvim_list_runtime_paths())
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
-- keep long temp paths on one terminal row so location lines don't wrap
vim.opt.columns = 220

vim.env.SHELL = "/bin/sh"

vim.cmd("runtime! plugin/plenary.vim")
