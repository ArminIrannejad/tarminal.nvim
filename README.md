# tarminal.nvim

Terminal runner / REPL integration for Neovim: a shared bottom-split shell
terminal for running files, filetype-aware REPLs for sending selections and
cells, and clickable error locations in terminal output.

## Features

- **Shared shell terminal** — toggle a bottom split running your shell;
  its buffer is reused across runs and can be shown independently per tab.
- **Run the current file** — saves the buffer and runs it with the runner
  configured for its filetype (`time`d), with a banner separating runs. From
  a non-file buffer it re-runs the last run. C files are compiled with the
  configured `runners.c` command (`cc` by default), using
  `-Wall -Wextra -Wpedantic -O2`, and then executed.
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

## Usage

**No keymaps are created by default** — everything is available through the
`:Tarminal` command, and you opt into keymaps via the `keymaps` option (see
the [example setup](#example-setup) below).

- `:Tarminal` / `:Tarminal toggle` — show/hide the shared shell terminal
- `:Tarminal run` — save and run the current file (from a non-file buffer:
  re-run the last run)
- `:Tarminal send_cell` — send the cell around the cursor to the REPL
- `:'<,'>Tarminal send_selection` — send the selected line range to the REPL
  (the optional visual-mode keymap preserves exact character/block selections)

In a terminal buffer:

- `:Tarminal jump_to_error` — jump to the file location on the current line
- `:Tarminal next_error` / `:Tarminal prev_error` — move between error
  locations
- `:Tarminal errors_to_quickfix` — collect error locations into the
  quickfix list; whether the terminal window closes and quickfix opens is
  controlled by the `quickfix` option

Errors are highlighted with the `TarminalError` highlight group (bold, in
your colorscheme's `DiagnosticError` red).

tarminal's terminals are named `tarminal://shell` and `tarminal://repl:<ft>`
and get the `tarminal` filetype. Other terminal buffers are never touched —
no global autocmds, no options or keymaps applied outside the plugin's own
buffers.

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
  quickfix = {                          -- errors_to_quickfix behavior
    open = true,                        --   open the quickfix window after collecting
    close_terminal = true,              --   close the terminal window after collecting
  },
  keymaps = {},                         -- none; every action stays reachable via :Tarminal
})
```

Runner and REPL tables are merged by filetype, so every default command can be
overridden independently. For example, `runners = { c = "clang" }` uses Clang
for C while retaining the other defaults.

## Example setup

The author's opinionated setup, with all keymaps wired up:

```lua
{
  "ArminIrannejad/tarminal.nvim",
  opts = {
    keymaps = {
      -- global in their respective normal/visual modes
      toggle = "<leader>ts",         -- toggle the shared shell terminal
      run = "<leader>ru",            -- save and run the current file
      send_selection = "<leader>ri", -- visual mode: send selection to REPL
      send_cell = "<leader>rc",      -- send cell around cursor to REPL
      -- buffer-local in tarminal's own terminals
      term_normal = "<Esc><Esc>",    -- terminal mode: exit to normal mode
      jump_to_error = "<CR>",        -- jump to file location on this line
      next_error = "]e",             -- next error location
      prev_error = "[e",             -- previous error location
      errors_to_quickfix = "<C-q>",  -- errors to quickfix and open it
    },
  },
}
```

Only the keys you set are mapped, so pick the subset you want.

## License

[MIT](./LICENSE)
