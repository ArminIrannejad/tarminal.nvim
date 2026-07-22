# tarminal.nvim

A terminal runner and REPL for Neovim.

It finds file locations in terminal output, lets you jump between errors, runs
the current file, and sends selections or cells to a REPL.

## Features

- Jump to errors such as `foo.c:12:5` or `File "foo.py", line 12`
- Move between errors or add them to the quickfix list
- Run the current file in a shared terminal split
- Run any command with `:Tarminal exec`
- Send selections and cells to a REPL
- Keep one shell terminal and one REPL per filetype

## Requirements

- Neovim 0.9 or newer
- Linux

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ArminIrannejad/tarminal.nvim",
  config = function()
    require("tarminal").setup()
  end,
}
```

With `vim.pack` on Neovim 0.12 or newer:

```lua
vim.pack.add({ "https://github.com/ArminIrannejad/tarminal.nvim" })
require("tarminal").setup()
```

## Keymaps

Here is a complete example using
`vim.keymap.set` for each one:

```lua
local tarminal = require("tarminal")

vim.keymap.set("n", "<leader>ts", tarminal.toggle, { desc = "Toggle terminal" })
vim.keymap.set("n", "<leader>ru", tarminal.run, { desc = "Run current file" })
vim.keymap.set("n", "<leader>re", tarminal.exec, { desc = "Run command" })
vim.keymap.set("x", "<leader>ri", tarminal.send_selection, { desc = "Send selection to REPL" })
vim.keymap.set("n", "<leader>rc", tarminal.send_cell, { desc = "Send cell to REPL" })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "tarminal",
  callback = function(args)
    vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], { buffer = args.buf })
    vim.keymap.set("n", "<CR>", tarminal.jump_to_error, { buffer = args.buf })
    vim.keymap.set("n", "]e", tarminal.next_error, { buffer = args.buf })
    vim.keymap.set("n", "[e", tarminal.prev_error, { buffer = args.buf })
    vim.keymap.set("n", "<C-q>", tarminal.errors_to_quickfix, { buffer = args.buf })
  end,
})
```

Put these after `require("tarminal").setup()`, or inside the `config` function
in your lazy.nvim spec.

## Commands

- `:Tarminal` or `:Tarminal toggle` toggles the shell terminal.
- `:Tarminal run` saves and runs the current file.
- `:Tarminal exec` asks for a command and remembers the last one.
- `:Tarminal exec {cmd}` runs a command. `%`, `%:r`, `%:t`, `#`, and other
  command-line expansions work here.
- `:Tarminal send_cell` sends the cell around the cursor to the REPL.
- `:'<,'>Tarminal send_selection` sends the selected lines to the REPL.
- `:Tarminal jump_to_error` jumps to the error on the current terminal line.
- `:Tarminal next_error` and `:Tarminal prev_error` move between errors.
- `:Tarminal errors_to_quickfix` adds all found errors to quickfix.

## Configuration

You only need to set the options you want to change:

```lua
require("tarminal").setup({
  split_height = 12,                    -- height of the terminal split
  split_position = "auto",              -- "auto", "bottom", or "top"
  shell = vim.env.SHELL or "/bin/bash",
  follow_run = "focus",                 -- "none", "focus", or "insert"
  follow_repl = "none",    
  autosave = true,
  park_on_error = true,                 -- highlight errors and park cursor on the first one
  cell_marker = "# COMMAND ----------", --line that delimits REPL "cells"
  time_runs = true,                     -- time the run (for compiled files: the binary)
  banner = true,                        --print banner before each run
  quickfix = {
    open = true,
    close_terminal = true,
  },
})
```

### Runners

Runners are set by filetype. tarminal adds the current file to the command:

```lua
require("tarminal").setup({
  runners = {
    python = "python",
    c = "clang -Wall -Wextra",
    zig = { cmd = "zig build-exe", run_binary = true },
    odin = { cmd = "odin run", args = "-file" },
  },
})
```

Common compilers such as `cc`, `gcc`, `clang`, and `rustc` are detected and
the built program is run. Use `run_binary = true` or `false` when you want to
choose that behavior yourself. `args` is added after the file path.


### REPLs

REPLs are also set by filetype:

```lua
require("tarminal").setup({
  repls = {
    python = "ipython",
    lua = "lua -i",
    haskell = {
      cmd = "ghci",
      bracketed_paste = false,
      block_open = ":{",
      block_close = ":}",
    },
  },
})
```

## License

[MIT](./LICENSE)
