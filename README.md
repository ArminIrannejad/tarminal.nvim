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

- `:Tarminal` or `:Tarminal toggle` hides every tarminal window, or brings them
  back as they were (the shell terminal the first time).
- `:Tarminal run` saves and runs the current file.
- `:Tarminal exec` asks for a command and remembers the last one.
- `:Tarminal exec {cmd}` runs a command. `%`, `%:r`, `%:t`, `#`, and other
  command-line expansions work here.
- `:Tarminal send_cell` sends the cell around the cursor to the REPL.
- `:'<,'>Tarminal send_selection` sends the selected lines to the REPL.
- `:Tarminal jump_to_error` jumps to the error on the current terminal line.
- `:Tarminal next_error` and `:Tarminal prev_error` move between errors.
- `:Tarminal errors_to_quickfix` adds all found errors to quickfix, replacing its
  own previous list rather than stacking a new one.

`<Tab>` completes subcommands, and file paths after `:Tarminal exec`.

## Configuration

You only need to set the options you want to change:

```lua
require("tarminal").setup({
  layout = "split",                     -- "split", "float", or a function
  split_height = 12,                    -- height of a top or bottom split
  split_width = 80,                     -- width of a left or right split
  split_position = "auto",              -- "auto", "bottom", "top", "left", or "right"
  float = { width = 0.8, height = 0.8, border = "rounded" },
  shell = vim.env.SHELL or "/bin/bash",
  follow_run = "focus",                 -- "none", "focus", or "insert"
  follow_repl = "none",
  autosave = true,
  park_on_error = true,                 -- highlight errors and park cursor on the first one
  diagnostics = false,                  -- show run errors as diagnostics in their files
  close_on_jump = false,                -- close the terminal once jump_to_error lands
  keep_term_name = false,               -- keep the term:// name instead of tarminal://shell
  any_terminal = false,                 -- navigate errors in terminals tarminal did not open
  win_opts = { number = false, relativenumber = false, scrolloff = 0 },
  error_threshold = 0,                  -- min severity to act on: 0 note, 1 warning, 2 error
  cell_marker = "# COMMAND ----------", -- line that delimits REPL "cells"
  time_runs = false,                    -- time the run (for compiled files: the binary)
  banner = true,                        -- print "===== RUN =====" before each run
  clear_run = true,                     -- wipe the terminal + scrollback before each run
  shell_integration = true,             -- OSC 7 cwd tracking where no OS probe answers
  quickfix = {
    open = true,
    close_terminal = true,
  },
})
```

### Layout

The terminal opens in a split by default, placed by `split_position`: `"auto"`
follows `'splitbelow'`, and `"left"` or `"right"` give a full height side
split `split_width` columns wide.

`layout = "float"` opens it in a centered float instead, titled after the
terminal. `float.width` and `float.height` are columns and lines, or a fraction
of the editor when 1 or less. A float hides itself after `jump_to_error` so you
land on the code rather than under it.

For anything else pass a function. It gets the terminal buffer and returns the
window to show it in:

```lua
require("tarminal").setup({
  layout = function(buf)
    vim.cmd("tabnew")
    return vim.api.nvim_get_current_win()
  end,
})
```

Toggling hides every tarminal window, the shell and any REPLs, in every tab.
The next toggle brings them all back where they were and at the size you left
them, so a terminal in its own tab gets its tab back instead of a new one.

### Your own terminal setup

tarminal opens plain `:terminal` buffers and adds to them rather than taking
over. Your `TermOpen` autocmds still run, and the `tarminal` filetype is set on
top so `FileType tarminal` can add what you only want there.

The buffers are named `tarminal://shell` and `tarminal://repl:<filetype>`. Set
`keep_term_name = true` to keep Neovim's own `term://` name instead, so your
`BufEnter term://*` and `TermClose term://*` autocmds fire in them too.

To tell tarminal's terminals apart in your own code, check `vim.b.is_shell`
(the shell terminal) and `vim.b.repl_ft` (the filetype a REPL terminal belongs
to). tarminal goes by these rather than the filetype, so changing it breaks
nothing.

`win_opts` are the window options set on a new terminal after your `TermOpen`
autocmds ran. They replace the default table whole, so `win_opts = {}` leaves
your own settings untouched.

Error navigation only acts on tarminal's own terminals by default. Set
`any_terminal = true` to use `jump_to_error`, `next_error`, `prev_error` and
`errors_to_quickfix` in any terminal, like one from another terminal plugin.

### Runs

Each run wipes the screen and the scrollback first, so the terminal shows the
output of that run and nothing else — no `cd`, no run command, no leftovers from
the run before. A `===== RUN: <time> =====` banner heads the output and focus
moves to the terminal window. Set `clear_run = false` to keep the history and
scroll back through it, `banner = false` to drop the banner line, and
`follow_run = "none"` to stay in the code window.

A run is refused while the terminal is busy with a command. When it is idle,
anything half-typed at the prompt is cancelled with `^C` first, so a line you
started and walked away from can never be glued onto the run command.

### Events

tarminal fires `User` autocmds you can hook into:

- `TarminalOpen` when it opens a terminal, with `buf`, `kind` (`"shell"` or
  `"repl"`), and `ft` for a REPL
- `TarminalRunStart` when a run or exec is sent, with `buf`, `cmd`, and `dir`
- `TarminalRunDone` when the shell is back at its prompt, with the same fields
  plus `duration` in milliseconds (to within a fraction of a second) and `code`

For example, to get told when a long run finishes:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "TarminalRunDone",
  callback = function(ev)
    local d = ev.data
    if d.duration > 5000 then
      vim.notify(("%s done in %ds"):format(d.cmd, d.duration / 1000))
    end
  end,
})
```

tarminal types nothing extra to learn the outcome. It watches the shell get the
terminal back, the same way it checks the terminal is busy. `code` is the exit
status when your shell reports it with OSC 133 semantic prompt marks, as fish 4
and many shell integrations do, and `nil` otherwise.

### Shell integration

A relative path in error output resolves against the directory the shell is
actually in — not the one it started in. Where the OS can be asked directly
(`/proc` on Linux/WSL and NetBSD, `lsof` on macOS, `procstat` on FreeBSD)
tarminal just asks it, and opens shells untouched: nothing is typed at the
prompt, nothing is cleared.

Only where no such probe answers — OpenBSD, or a stripped-down system missing
`lsof`/procfs — does tarminal type a one-line setup snippet at the prompt and
clear the screen after it. The snippet installs a prompt hook that reports the
working directory via OSC 7.

Only `bash`, `zsh`, and `fish` are recognized, by the basename of `shell`. Any
other shell is left alone, and tarminal falls back to Neovim's working
directory.

The snippet only defines a function and registers a prompt hook in tarminal's
own terminals — your shell rc files are never touched, and no shell outside
Neovim is affected. Turn it off with `shell_integration = false`.

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

A runner can also be a function. It gets the file, its stem, dir, and filetype
and returns the command to run as is, plus an optional directory to run it in:

```lua
runners = {
  python = function(ctx)
    if ctx.file:match("test_[^/]*%.py$") then
      return "pytest " .. vim.fn.shellescape(ctx.file)
    end
    return "python " .. vim.fn.shellescape(ctx.file)
  end,
},
```

### Project runners

Inside a project the file is often the wrong thing to run. `project_runners`
are tried first: when a `marker` file is found above the current file, `cmd`
runs as is from that directory. The defaults run `cargo run` under a
`Cargo.toml` (with `--example <name>` for files in `examples/` and `--bin
<name>` for files in `src/bin/`) and `zig build run` under a `build.zig`.

```lua
require("tarminal").setup({
  project_runners = {
    { marker = "Makefile", cmd = "make run", ft = { "c", "cpp" } },
    { marker = "package.json", cmd = "npm start", ft = "javascript" },
  },
})
```

Your entries are tried before the defaults. `ft` limits an entry to some
filetypes and leaving it out applies it to all. `cmd` can also be a function
that gets the run context and the project root and returns the command, or
nothing to try the next entry. Set `project_runners = false` to always run the
file.

Runner functions and project runners are timed with `time_runs` like any other
run, and get a copy of the context so they can't change what a re-run uses.


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

### Diagnostics

Set `diagnostics = true` to also publish the locations a run prints as
`vim.diagnostic` entries in the files they point at, so they show inline next
to your code and in `vim.diagnostic.setqflist()` or any diagnostics picker.

The message is the text after the location. When nothing follows it, as with
rustc's `--> file:line:col`, it is the line above. Python traceback frames get
the exception their traceback ends in, like `ValueError: bad (in f)`.

They respect `error_threshold`, come from the `tarminal` source, and are
cleared when the next run starts. No buffers are created for them: a file you
don't have open gets its diagnostics when you open it.

## License

[MIT](./LICENSE)
