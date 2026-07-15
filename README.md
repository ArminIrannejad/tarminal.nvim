# tarminal.nvim

Terminal runner / REPL integration for Neovim: a shared bottom-split shell
terminal for running files, filetype-aware REPLs for sending selections and
cells, and clickable error locations in terminal output.

## Features

- **Shared shell terminal** — toggle a bottom split running your shell;
  reused across runs.
- **Run the current file** — saves the buffer and runs it with the runner
  configured for its filetype (`time`d), with a banner separating runs. From
  a non-file buffer it re-runs the last run. C files are compiled with
  `cc -Wall -Wextra -Wpedantic -O2` and then executed.
- **Error navigation** — file locations in the output (`foo.c:12:5:`,
  `File "foo.py", line 12`, …) are highlighted; `<CR>` on a line jumps to
  the location (wrapped long lines are handled), `]e`/`[e` move between
  locations, `<C-q>` collects them into the quickfix list. After a run the
  cursor is parked on the first error so a single `<CR>` jumps to it.
- **REPL integration** — send the visual selection or the "cell" around the
  cursor (delimited by `cell_marker` lines) to a per-filetype REPL, wrapped
  in bracketed paste so multi-line blocks paste cleanly.

## Requirements

- Neovim >= 0.9
- Linux (error-location resolution reads the shell's cwd from `/proc`)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ArminIrannejad/tarminal.nvim",
  opts = {},
}
```

With [`vim.pack`](https://neovim.io/doc/user/pack.html) (built-in, Neovim >= 0.12):

```lua
vim.pack.add({ "https://github.com/ArminIrannejad/tarminal.nvim" })
require("tarminal").setup()
```

## Configuration

Defaults:

```lua
require("tarminal").setup({
  split_height = 12,                    -- height of the bottom terminal split
  shell = vim.env.SHELL or "/bin/bash", -- shell for the shared terminal
  follow_run = "focus",                 -- focus after a run: "none" | "focus" | "insert"
  follow_repl = "none",                 -- focus after sending to a REPL
  park_on_error = true,                 -- highlight errors and park cursor on the first one
  cell_marker = "# COMMAND ----------", -- line that delimits REPL cells
  runners = {                           -- filetype -> command that runs a file
    python = "python",
    sh = "bash",
    lua = "lua",
    go = "go run",
    haskell = "runghc",
    ocaml = "ocaml",
    c = "cc",
  },
  repls = {                             -- filetype -> interactive REPL command
    python = "ipython",
    lua = "lua -i",
    haskell = "ghci",
    ocaml = "ocaml",
  },
  keymaps = {
    toggle = "<leader>ts",              -- toggle the shared shell terminal
    run = "<leader>ru",                 -- save and run the current file
    send_selection = "<leader>ri",      -- visual mode: send selection to REPL
    send_cell = "<leader>rc",           -- send cell around cursor to REPL
    -- buffer-local, in terminal normal mode:
    jump_to_error = "<CR>",
    next_error = "]e",
    prev_error = "[e",
    errors_to_quickfix = "<C-q>",
  },
})
```

`<Esc><Esc>` in terminal-mode is mapped to exit to normal mode.

## Usage

Keymaps above, or the `:Tarminal` command:

- `:Tarminal` / `:Tarminal toggle` — show/hide the shared shell terminal
- `:Tarminal run` — save and run the current file
- `:Tarminal send_cell` — send the cell around the cursor to the REPL
- `:'<,'>Tarminal send_selection` — send the visual selection to the REPL

Errors are highlighted with the `TarminalError` highlight group (bold, in
your colorscheme's `DiagnosticError` red).

## Development

```sh
make test    # run tests (requires plenary.nvim, cloned automatically)
make lint    # check formatting with stylua
make fmt     # format lua sources with stylua
```

## License

[MIT](./LICENSE)
