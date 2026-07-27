-- Minimal init used by the test runner (see Makefile).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = root .. "/.deps/plenary.nvim"

-- Drop the packpath first: a copy of tarminal installed under the user's
-- site/pack would otherwise win the `require` and the suite would silently
-- test that copy instead of this tree. The runtimepath is left alone so
-- bundled parsers and ftplugins still resolve.
vim.opt.packpath = {}
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
-- keep long temp paths on one terminal row so location lines don't wrap
vim.opt.columns = 220

vim.env.SHELL = "/bin/sh"

vim.cmd("runtime! plugin/plenary.vim")
