-- Minimal init used by the test runner (see Makefile).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = root .. "/.deps/plenary.nvim"

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
-- keep long temp paths on one terminal row so location lines don't wrap
vim.opt.columns = 220

if (vim.uv or vim.loop).os_uname().sysname == "Windows_NT" then
  -- forward-slash tempname()/getcwd() and POSIX-style shellescape
  vim.o.shellslash = true
  -- explicit Git Bash paths dodge System32's WSL bash.exe shadowing PATH
  local bash
  for _, p in ipairs({
    vim.env.TARMINAL_TEST_BASH,
    "C:/Program Files/Git/usr/bin/bash.exe",
    "C:/Program Files/Git/bin/bash.exe",
  }) do
    if p and vim.fn.filereadable(p) == 1 then
      bash = p
      break
    end
  end
  vim.env.SHELL = bash or "bash"
else
  vim.env.SHELL = "/bin/sh"
end

vim.cmd("runtime! plugin/plenary.vim")
