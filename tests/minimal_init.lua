-- Minimal init used by the test runner (see Makefile).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = root .. "/.deps/plenary.nvim"

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
-- keep long temp paths on one terminal row so location lines don't wrap
vim.opt.columns = 220

vim.env.SHELL = "/bin/sh"

vim.cmd("runtime! plugin/plenary.vim")
