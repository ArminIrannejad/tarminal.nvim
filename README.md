# tarminal.nvim

Terminal runner / REPL integration for Neovim: a shared split shell
terminal for running files, filetype-aware REPLs for sending selections and
cells, and clickable error locations in terminal output.

## Features

- **Shared shell terminal** — toggle a full-width split running your shell;
  it opens where your `'splitbelow'` setting puts splits (overridable with
  `split_position`). Its buffer is reused across runs and can be shown
  independently per tab.
- **Run the current file** — saves the buffer and runs it with the runner
  configured for its filetype (`time`d unless disabled), with a banner
  separating runs (`banner = false` turns it off). From a non-file buffer
  it re-runs the last run. Compiler commands are recognized automatically,
  so `c = "clang -Wall"` compiles the file and runs the resulting binary.
- **Run any command** — `:Tarminal exec` works like emacs' `M-x compile`:
  prompts for a command (pre-filled with the last one), expands `%`-style
  cmdline specials, and gives the output the same banner and clickable
  errors as a run.
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
- `:Tarminal exec {cmd}` — run an arbitrary command in the terminal, emacs
  `M-x compile` style. Without `{cmd}` it always prompts, pre-filled with the
  last command, so plain Enter re-runs it. Cmdline specials in `{cmd}` are
  expanded first: `%` is the current file, and `%:r`, `%:t`, `#`, `<cword>`,
  … all work (`:h cmdline-special`; use `%:S` if the path needs shell
  quoting) — so `:Tarminal exec make %:r` or `gcc -O2 % -o %:r && ./%:r`
  without typing paths. The prefilled command at the prompt is already
  expanded and re-runs verbatim, so a bare `exec` from a non-file buffer
  never re-resolves `%` against the terminal itself.
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
  split_height = 12,                    -- height of the terminal split
  split_position = "auto",              -- "auto" (follow 'splitbelow') | "bottom" | "top"
  shell = vim.env.SHELL or "/bin/bash", -- shell for the shared terminal
  follow_run = "focus",                 -- focus after a run: "none" | "focus" | "insert"
  follow_repl = "none",                 -- focus after sending to a REPL
  autosave = true,                      -- write the buffer before a run/exec
  park_on_error = true,                 -- highlight errors and park cursor on the first one
  cell_marker = "# COMMAND ----------", -- line that delimits REPL cells
  time_runs = true,                     -- `time` the run (for compiled files: the binary)
  banner = true,                        -- print a "===== RUN[n]: <time> =====" line before each run
  runners = {                           -- filetype -> command used to run a file
    python = "python",                  --   interpreted: `python foo.py`
    sh = "bash",
    lua = "lua",
    javascript = "node",
    go = "go run",
    haskell = "runghc",
    ocaml = "ocaml",
    c = "cc",                          --   compiler: `cc foo.c -o foo && ./foo`
    rust = "rustc",
    odin = { cmd = "odin run", args = "-file" }, -- `odin run foo.odin -file`
  },
  compilers = {                         -- executable names recognized as compilers
    "cc", "gcc", "clang", "g++", "clang++", "c++", 
    "rustc", "ghc", "swiftc", "gdc", "ocamlopt", "ocamlc",
  },
  repls = {                             -- filetype -> interactive REPL command
    python = "ipython",
    lua = "lua -i",
    haskell = "ghci",
    ocaml = { cmd = "ocaml", bracketed_paste = false },
  },
  quickfix = {                          -- errors_to_quickfix behavior
    open = true,                        --   open the quickfix window after collecting
    close_terminal = true,              --   close the terminal window after collecting
  },
})
```

Runner and REPL tables are merged by filetype, so every default command can be
overridden independently; the same goes for `repls`. For an interpreted
runner, tarminal appends the file (`python foo.py`). When the command's first
program is listed in `compilers`, tarminal instead builds and runs it
(`clang -Wall foo.c -o foo && ./foo`). Paths and version suffixes are handled,
so `/usr/bin/clang-17 -Wall` is recognized too.

For a compiler the name detection doesn't know, a runner entry can also be a
table with an explicit `compile` flag — no need to touch the `compilers` list:

```lua
runners = {
  zig = { cmd = "zig build-exe", compile = true },  -- build with -o, run the binary
  c   = { cmd = "cc", compile = false },            -- force running the file directly
}
```

With `compile` unset (or a plain string entry), compile-then-run is inferred
from the command's program name via `compilers` as above.

A table entry can also carry `args`, appended *after* the file, for tools that
require `<cmd> <file> <flag>` order rather than accepting the file last. This is
how the bundled Odin runner works — `{ cmd = "odin run", args = "-file" }`
produces `odin run foo.odin -file`, since Odin reads a bare path as a package
directory and needs `-file` (which must follow the path) to run a single source
file. Odin isn't in `compilers` because `odin run` builds and runs in one step
and uses `-out:`, not `-o`.
With `time_runs` enabled, runs are prefixed with `time` — but only when a
`time` binary is installed, so the command works in any POSIX shell instead
of relying on a shell keyword; without one, timing is silently skipped. For
compiled files only the produced binary is timed, not compilation.

With `autosave = false` tarminal never writes for you: a run or exec uses
whatever is currently on disk, so unsaved edits won't be picked up. This
covers all three save points — running the current file, re-running the last
file from a non-file buffer, and `exec` from a file buffer.

With `banner = false` a run prints nothing extra: no banner line, and the
previous screen is not pushed into scrollback first — output simply appends
at the prompt, like a hand-typed command. Error highlighting and quickfix
collection still track the new run's output; only the view pinning to the
banner is skipped.

Everything tarminal types at the shell prompt (run commands, `cd`s, REPL
launches) is prefixed with a space, so it stays out of your shell history if
the shell is configured to skip space-prefixed commands: `setopt
HIST_IGNORE_SPACE` in zsh, `HISTCONTROL=ignorespace` (or `ignoreboth` — the
Debian/Ubuntu default) in bash; fish does this out of the box. Text sent
*into* a REPL lands in the REPL's own history, where recalling it is usually
what you want.

A `repls` entry is the REPL command, or a table `{ cmd = ..., bracketed_paste
= false }` for REPLs that read raw stdin and would see the bracketed-paste
escape sequences as input — like the stock `ocaml` toplevel (the default
entry). With `bracketed_paste = false` the text is sent unwrapped.

The `shell` command is split on whitespace and spawned directly, without a
wrapper shell — any POSIX-compatible shell works. (With a shell that lacks
job control, like dash, the busy-terminal guard degrades to a no-op.)

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
      c = "clang -Wall -Wextra -Wpedantic -O2",
    },
  },
  keys = {
    { "<leader>ts", function() require("tarminal").toggle() end, desc = "Toggle shell terminal" },
    { "<leader>ru", function() require("tarminal").run() end, desc = "Run current file in terminal" },
    { "<leader>re", function() require("tarminal").exec() end, desc = "Run command in terminal (prompts)" },
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
