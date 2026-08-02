# tarminal.nvim

A terminal runner and REPL for Neovim.

It finds file locations in terminal output, lets you jump between errors, runs
the current file, and sends selections or cells to a REPL.

## Features

- Jump to errors such as `foo.c:12:5` or `File "foo.py", line 12`
- Add patterns for other error formats, with warning/error severity
- Move between errors or add them to the quickfix list
- Run the current file in a shared terminal split
- Run any command with `:Tarminal exec`
- Send selections and cells to a REPL
- Keep one shell terminal and one REPL per filetype

## Requirements

- Neovim 0.10 or newer
- A Unix-like OS: Linux (incl. WSL), macOS, or BSD

Run `:checkhealth tarminal` to verify the platform probes, your shell, and the
configured runners and REPLs.

## Install

Pin to the latest release — `main` is a moving target and may be ahead of any
released version.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ArminIrannejad/tarminal.nvim",
  version = "*", -- latest release
}
```

With `vim.pack` on Neovim 0.12 or newer:

```lua
vim.pack.add({
  { src = "https://github.com/ArminIrannejad/tarminal.nvim", version = vim.version.range("*") },
})
```

`setup()` is optional — call it only to change defaults.

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

Put these anywhere in your config, or inside the `keys`/`config` block of your
lazy.nvim spec.

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

`<Tab>` completes subcommands, and file paths after `:Tarminal exec`.

## Configuration

You only need to set the options you want to change:

```lua
require("tarminal").setup({
  split_height = 12,                    -- height of the terminal split
  split_position = "auto",              -- "auto", "bottom", or "top"
  shell = vim.env.SHELL or "/bin/bash",
  follow_run = "none",                  -- "none", "focus", or "insert"
  follow_repl = "none",
  autosave = true,
  park_on_error = true,                 -- highlight errors and park cursor on the first one
  close_on_jump = false,                -- close the terminal once jump_to_error lands
  error_threshold = 0,                  -- min severity to act on: 0 note, 1 warning, 2 error
  cell_marker = "# COMMAND ----------", -- line that delimits REPL "cells"
  time_runs = false,                    -- time the run (for compiled files: the binary)
  banner = false,                       -- print "===== RUN =====" before each run
  clear_run = true,                     -- wipe the terminal + scrollback before each run
  shell_integration = true,             -- track the shell's cwd via OSC 7
  quickfix = {
    open = true,
    close_terminal = true,
  },
})
```

### Runs

Each run wipes the screen and the scrollback first, so the terminal shows the
output of that run and nothing else — no `cd`, no run command, no leftovers from
the run before. Set `clear_run = false` to keep the history and scroll back
through it; pair it with `banner = true` to mark where each run starts.

A run is refused while the terminal is busy with a command. When it is idle,
anything half-typed at the prompt is cancelled with `^C` first, so a line you
started and walked away from can never be glued onto the run command.

### Shell integration

When tarminal opens a shell terminal it types a one-line setup snippet at the
prompt, then clears the screen so the snippet and its output aren't left
behind. The snippet installs a prompt hook that reports the working directory
via OSC 7, so a relative path in error output resolves against the directory
the shell is actually in — not the one it started in.

Only `bash`, `zsh`, and `fish` are recognized, by the basename of `shell`. Any
other shell is left alone: nothing is typed, nothing is cleared, and tarminal
falls back to a per-OS probe (`/proc`, `lsof`, `procstat`), then to Neovim's
working directory.

It only defines a function and registers a prompt hook in tarminal's own
terminals — your shell rc files are never touched, and no shell outside Neovim
is affected. Turn it off with `shell_integration = false`.

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

### Errors

tarminal recognizes an error location by matching each terminal line against a
list of patterns. Each pattern says where the file, line, column, and (optional)
severity are. The built-ins cover the common `path:line:col` and `File "..."`
shapes; add your own for tools they miss:

```lua
require("tarminal").setup({
  error_patterns = {
    -- "Died at /path/script.pl line 42."
    { pattern = "at (%S+) line (%d+)", file = 1, lnum = 2, resolve = false },
  },
})
```

`file`, `lnum`, `col`, and `type` are capture indices in `pattern`. Your patterns
are tried before the built-ins. By default a match only counts if the file
exists on disk (so false positives stay out); set `resolve = false` to trust the
pattern and take the path as written — useful when the path won't resolve against
the terminal's directory (output from a subfolder, another machine).

`type` classifies a location as an error, warning, or note (either a capture
index holding the word, or a fixed `"error"`/`"warning"`/`"info"`). Warnings get
their own highlight (`TarminalWarning`), quickfix entries carry the severity, and
`error_threshold` skips anything below it when parking, stepping between errors
(`next_error`/`prev_error`), and collecting — set it to `2` to ignore warnings.
Pressing Enter (`jump_to_error`) on a line always jumps to its location, whatever
the severity. Set `close_on_jump = true` to close the terminal on the way out, so
you land on the error with the split gone — the same thing `quickfix.close_terminal`
does for `errors_to_quickfix`.

## License

[MIT](./LICENSE)
