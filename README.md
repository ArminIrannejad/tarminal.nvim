# tarminal.nvim

Terminal runner / REPL integration for Neovim: a shared bottom-split shell
terminal for running files, filetype-aware REPLs for sending selections and
cells, and clickable error locations in terminal output.

## Features

- **Shared shell terminal** — toggle a bottom split running your shell;
  its buffer is reused across runs and can be shown independently per tab.
- **Run the current file** — saves the buffer and runs it with the runner
  configured for its filetype (wrapped in `time` unless disabled), with a
  banner separating runs. From a non-file buffer it re-runs the last run.
  Compiled runners (C by default) build the file and run the resulting
  binary.
- **Error navigation** — file locations in the output (`foo.c:12:5:`,
  `File "foo.py", line 12`, …) are highlighted; jump to the location under
  the cursor (wrapped long lines are handled), move between locations, or
  collect them into the quickfix list. After a run the cursor is parked on
  the first error so a single jump lands on it.
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

**tarminal never creates keymaps** — `setup()` takes settings only. Every
action is available through the `:Tarminal` command and as a Lua function
(`require("tarminal").toggle()`, `.run()`, …), so you map exactly the keys
you want yourself (see the [example setup](#example-setup) below).

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
  time_runs = true,                     -- wrap runs in `time` (compiled runners: the binary)
  runners = {                           -- filetype -> how to run a file
    python = "python",                  --   string: run the file, `python foo.py`
    sh = "bash",
    lua = "lua",
    go = "go run",
    haskell = "runghc",
    ocaml = "ocaml",
    c = { cmd = "cc", compile = true }, --   compile: `cc foo.c -o foo && ./foo`
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
})
```

Runner and REPL tables are merged by filetype, so every default command can be
overridden independently; the same goes for `repls`. A string runner runs the
file directly; a table with `compile = true` builds it first and runs the
result. Flags belong in the command itself, and since the merge is per-field,
`runners = { c = { cmd = "clang -Wall -Wextra -O2" } }` changes only the
compile command while keeping `compile = true` from the default.

Set `quickfix = { open = false, close_terminal = false }` if you want
`errors_to_quickfix` to only populate the quickfix list, leaving the terminal
window exactly as it is.

## Example setup

The author's opinionated setup — global keymaps in the lazy.nvim spec, and
buffer-local keymaps for tarminal's own terminals via the `tarminal`
filetype (which fires for every terminal the plugin creates):

```lua
{
  "ArminIrannejad/tarminal.nvim",
  opts = {
    runners = {
      c = { cmd = "cc -Wall -Wextra -Wpedantic -O2" },
    },
  },
  keys = {
    { "<leader>ts", function() require("tarminal").toggle() end, desc = "Toggle shell terminal" },
    { "<leader>ru", function() require("tarminal").run() end, desc = "Run current file in terminal" },
    { "<leader>ri", function() require("tarminal").send_selection() end, mode = "x", desc = "Send selection to REPL" },
    { "<leader>rc", function() require("tarminal").send_cell() end, desc = "Send cell to REPL" },
  },
  init = function()
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "tarminal",
      callback = function(ev)
        local t = require("tarminal")
        local function map(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = ev.buf, desc = desc })
        end
        map("t", "<Esc><Esc>", [[<C-\><C-n>]], "Exit terminal mode")
        map("n", "<CR>", t.jump_to_error, "Jump to file location on this line")
        map("n", "]e", t.next_error, "Next error location")
        map("n", "[e", t.prev_error, "Previous error location")
        map("n", "<C-q>", t.errors_to_quickfix, "Errors to quickfix")
      end,
    })
  end,
}
```

With `vim.pack` the same keymaps work verbatim — just call
`require("tarminal").setup()` first and drop the lazy.nvim spec wrapper.

## License

[MIT](./LICENSE)
