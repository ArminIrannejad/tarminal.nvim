local helpers = require("tests.helpers")

describe("tarminal run", function()
  local tarminal = require("tarminal")
  local platform = require("tarminal.platform")
  local run = require("tarminal.run")
  local term = require("tarminal.term")

  local banner_rows = helpers.banner_rows
  local wait_run_finished = helpers.wait_run_finished
  local stdin_capture_shell = helpers.stdin_capture_shell
  local wait_capture = helpers.wait_capture
  local find_term_buf = helpers.find_term_buf

  helpers.hooks()

  it("automatically compiles and runs compiler-based runners", function()
    tarminal.setup({ time_runs = false, runners = { c = "clang -Wpedantic -Wall" } })
    local build = run.build_runner_command
    local command = build({
      file = "/tmp/example.c",
      stem = "example",
      dir = "/tmp",
      ft = "c",
    })
    assert.equals("clang -Wpedantic -Wall '/tmp/example.c' -o 'example' && ./'example'", command)
  end)

  it("appends the file to interpreted runners", function()
    tarminal.setup({ time_runs = false })
    local build = run.build_runner_command
    local ctx = { file = "/tmp/example.py", stem = "example", dir = "/tmp", ft = "python" }
    assert.equals("python '/tmp/example.py'", build(ctx))
  end)

  it("times runs only when a time binary is installed", function()
    tarminal.setup({ time_runs = true })
    local build = run.build_runner_command
    local py = { file = "/tmp/example.py", stem = "example", dir = "/tmp", ft = "python" }
    local c = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }

    if vim.fn.executable("time") == 1 then
      assert.equals("time python '/tmp/example.py'", build(py))
      -- for a compile chain only the produced binary is timed
      assert.equals("cc '/tmp/example.c' -o 'example' && time ./'example'", build(c))
    else
      -- no binary so the prefix is skipped and any POSIX shell can run this
      assert.equals("python '/tmp/example.py'", build(py))
      assert.equals("cc '/tmp/example.c' -o 'example' && ./'example'", build(c))
    end
  end)

  it("does not overwrite an extensionless source file when compiling", function()
    tarminal.setup({ time_runs = false })
    local build = run.build_runner_command
    local command = build({ file = "/tmp/prog", stem = "prog", dir = "/tmp", ft = "c" })
    assert.equals("cc '/tmp/prog' -o 'prog.out' && ./'prog.out'", command)
  end)

  it("builds and runs the binary when a table runner sets run_binary", function()
    tarminal.setup({
      time_runs = false,
      runners = { zig = { cmd = "zig build-exe", run_binary = true } },
    })
    local build = run.build_runner_command
    local command = build({
      file = "/tmp/example.zig",
      stem = "example",
      dir = "/tmp",
      ft = "zig",
    })
    assert.equals("zig build-exe '/tmp/example.zig' -o 'example' && ./'example'", command)
  end)

  it("runs the file directly when a table runner sets run_binary = false", function()
    tarminal.setup({
      time_runs = false,
      runners = { c = { cmd = "cc", run_binary = false } },
    })
    local build = run.build_runner_command
    local ctx = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }
    assert.equals("cc '/tmp/example.c'", build(ctx))
  end)

  it("infers running the binary by name for a table runner without a run_binary flag", function()
    tarminal.setup({ time_runs = false, runners = { c = { cmd = "clang -Wall" } } })
    local build = run.build_runner_command
    local ctx = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }
    assert.equals("clang -Wall '/tmp/example.c' -o 'example' && ./'example'", build(ctx))
  end)

  it("appends a runner's args after the file", function()
    tarminal.setup({ time_runs = false })
    local build = run.build_runner_command
    -- the bundled odin runner is `odin run <file> -file`
    local ctx = { file = "/tmp/example.odin", stem = "example", dir = "/tmp", ft = "odin" }
    assert.equals("odin run '/tmp/example.odin' -file", build(ctx))
  end)

  it("places args after the source in a compiling runner", function()
    tarminal.setup({
      time_runs = false,
      runners = { c = { cmd = "cc", args = "-lm", run_binary = true } },
    })
    local build = run.build_runner_command
    local ctx = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }
    assert.equals("cc '/tmp/example.c' -lm -o 'example' && ./'example'", build(ctx))
  end)

  it("recognizes compiler paths and versioned compiler names", function()
    local build = run.build_runner_command
    local ctx = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }

    tarminal.setup({ time_runs = false, runners = { c = "/usr/bin/clang-17 -Wall" } })
    assert.equals("/usr/bin/clang-17 -Wall '/tmp/example.c' -o 'example' && ./'example'", build(ctx))
  end)

  it("runs a named file with its configured runner", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    tarminal.run()

    local term_buf = find_term_buf()
    vim.fn.delete(file)
    assert.is_not_nil(term_buf)
    assert.equals(vim.fn.fnamemodify(file, ":h"), vim.b[term_buf].term_cwd)
  end)

  it("aborts the run when the file cannot be written", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    -- unsaved edits in a readonly buffer make update fail and the run
    -- must not silently execute the stale on-disk version
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "print('edited')" })
    vim.bo.readonly = true
    local before = tarminal._run_id

    tarminal.run()

    vim.bo.readonly = false
    vim.fn.delete(file)
    assert.equals(before, tarminal._run_id)
  end)

  it("saves the edited source before a re-run from the terminal", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ banner = true, park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    tarminal.run()
    local src = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(src, -1, -1, false, { "print('edited')" })
    assert.is_true(vim.bo[src].modified)

    -- re-run from inside the terminal window
    local term_win
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "tarminal" then
        term_win = win
      end
    end
    assert.is_not_nil(term_win)
    assert.is_true(wait_run_finished(vim.api.nvim_win_get_buf(term_win), 1))
    vim.api.nvim_set_current_win(term_win)
    tarminal.run()

    local saved = not vim.bo[src].modified
    vim.fn.delete(file)
    assert.is_true(saved)
  end)

  it("runs without saving when autosave is off", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ autosave = false, park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    local src = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(src, -1, -1, false, { "print('edited')" })
    local before = tarminal._run_id

    tarminal.run()

    local still_modified = vim.bo[src].modified
    local ran = tarminal._run_id == before + 1
    vim.fn.delete(file)
    -- the run goes through against the on-disk version with the buffer untouched
    assert.is_true(ran)
    assert.is_true(still_modified)
  end)

  it("does not abort an unwritable run when autosave is off", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ autosave = false, park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    -- the readonly buffer that aborts the run with autosave on is never
    -- written here so there is nothing to fail on
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "print('edited')" })
    vim.bo.readonly = true
    local before = tarminal._run_id

    tarminal.run()

    vim.bo.readonly = false
    vim.fn.delete(file)
    assert.equals(before + 1, tarminal._run_id)
  end)

  it("refuses to run while the terminal is busy with a command", function()
    -- foreground-job detection needs a shell with job control
    -- a plain POSIX sh runs children in its own process group where the
    -- busy guard degrades to a no-op
    -- so pin bash rather than inherit $SHELL
    local bash = "bash"
    if vim.fn.executable(bash) == 0 then
      return
    end
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    -- a runner that keeps the shell's foreground occupied
    -- generously long so it still runs when the second run() is attempted
    -- even on a slow CI runner
    -- after_each kills the shell well before it expires
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ "sleep 30" }, script)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({
      park_on_error = false,
      follow_run = "none",
      shell = bash,
      runners = { lua = "sh " .. script },
    })

    tarminal.run()
    local first_id = tarminal._run_id

    local term_buf = find_term_buf()
    assert.is_not_nil(term_buf)
    local term_busy = platform.term_busy
    local busy = vim.wait(8000, function()
      return term_busy(term_buf) == true
    end, 50)
    assert.is_true(busy)

    tarminal.run()
    assert.equals(first_id, tarminal._run_id)
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)

  it("drops input typed at the prompt before sending a run", function()
    -- both the busy probe and ^C line editing need a job-control shell
    if vim.fn.executable("bash") == 0 then
      return
    end
    local marker = vim.fn.tempname()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({
      banner = true,
      clear_run = false, -- keep both banners in the buffer
      park_on_error = false,
      follow_run = "none",
      shell = "bash",
      runners = { lua = "true" },
    })

    tarminal.run()
    local term_buf = find_term_buf()
    assert.is_not_nil(term_buf)
    assert.is_true(wait_run_finished(term_buf, 1))

    -- a half-written command left at the prompt and never entered
    term.term_send(term_buf, "echo glued > " .. marker)
    tarminal.run()
    assert.is_true(wait_run_finished(term_buf, 2))

    local glued = vim.fn.filereadable(marker) == 1
    vim.fn.delete(marker)
    vim.fn.delete(file)
    assert.is_false(glued)
  end)

  it("sends run commands with a history-suppressing leading space", function()
    -- a "shell" that copies its stdin to a file so the exact bytes
    -- tarminal types at the prompt can be inspected
    local out = vim.fn.tempname()
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ "trap '' INT", "exec cat > " .. out }, script)
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({
      clear_run = false, -- keep `cd` first in the typed line
      park_on_error = false,
      follow_run = "none",
      shell = "sh " .. script,
      runners = { lua = "true" },
    })

    tarminal.run()

    local received = vim.wait(8000, function()
      return vim.fn.filereadable(out) == 1 and (vim.fn.readfile(out)[1] or ""):find("cd", 1, true) ~= nil
    end, 50)
    local first_line = (vim.fn.readfile(out)[1] or "")
    vim.fn.delete(out)
    vim.fn.delete(script)
    vim.fn.delete(file)
    assert.is_true(received)
    assert.equals(" cd '", first_line:sub(1, 5))
  end)

  it("does not pad bannered runs with blank terminal lines", function()
    local out, script = stdin_capture_shell()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({
      banner = true,
      clear_run = false,
      park_on_error = false,
      follow_run = "none",
      shell = "sh " .. script,
      runners = { lua = "true" },
    })

    tarminal.run()

    assert.is_true(wait_capture(out, "RUN"))
    local command = table.concat(vim.fn.readfile(out), "\n")
    vim.fn.delete(out)
    vim.fn.delete(script)
    vim.fn.delete(file)
    assert.is_nil(command:find("\\n\\n", 1, true))
    assert.is_nil(command:find("\\033[H", 1, true))
  end)

  it("wipes the screen ahead of the cd and the run command by default", function()
    local out, script = stdin_capture_shell()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({
      park_on_error = false,
      follow_run = "none",
      shell = "sh " .. script,
      runners = { lua = "true" },
    })

    tarminal.run()

    assert.is_true(wait_capture(out, "cd "))
    local command = table.concat(vim.fn.readfile(out), "\n")
    vim.fn.delete(out)
    vim.fn.delete(script)
    vim.fn.delete(file)
    -- the wipe runs first so neither the cd nor the run command survives it
    local wipe = command:find("\\033[3J", 1, true)
    assert.is_not_nil(wipe)
    assert.is_true(wipe < command:find("cd ", 1, true))
  end)

  it("exec expands % against the current file", function()
    local out, script = stdin_capture_shell()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    tarminal.setup({ banner = false, park_on_error = false, follow_run = "none", shell = "sh " .. script })

    -- the shape the :Tarminal command dispatcher passes with raw .args
    -- plus the pre-tokenized .fargs
    tarminal.exec({ args = "exec echo %", fargs = { "exec", "echo", "%" } })

    local received = wait_capture(out, "echo " .. file)
    vim.fn.delete(out)
    vim.fn.delete(script)
    vim.fn.delete(file)
    assert.is_true(received)
  end)

  it("exec preserves shell quoting from the raw command line", function()
    local out, script = stdin_capture_shell()
    tarminal.setup({ banner = false, park_on_error = false, follow_run = "none", shell = "sh " .. script })

    -- .fargs would collapse the quotes to `echo a  b` with two args and
    -- lost spacing while .args keeps the literal command
    tarminal.exec({ args = "exec echo 'a  b'", fargs = { "exec", "echo", "a  b" } })

    local received = wait_capture(out, "echo 'a  b'")
    vim.fn.delete(out)
    vim.fn.delete(script)
    assert.is_true(received)
  end)

  it("exec prompts pre-filled with the last command", function()
    local out, script = stdin_capture_shell()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    tarminal.setup({ banner = false, park_on_error = false, follow_run = "none", shell = "sh " .. script })

    tarminal.exec("echo first_exec")
    assert.is_true(wait_capture(out, "echo first_exec"))

    local seen_default
    local orig = vim.ui.input
    vim.ui.input = function(opts, on_confirm) ---@diagnostic disable-line: duplicate-set-field
      seen_default = opts.default
      on_confirm(nil) -- cancel
    end
    tarminal.exec()
    vim.ui.input = orig

    vim.fn.delete(out)
    vim.fn.delete(script)
    vim.fn.delete(file)
    assert.equals("echo first_exec", seen_default)
  end)

  it("exec from a non-file buffer prompts and reruns the expanded command verbatim", function()
    local out, script = stdin_capture_shell()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    tarminal.setup({ banner = false, park_on_error = false, follow_run = "none", shell = "sh " .. script })

    tarminal.exec("echo ran %")
    local expanded = "echo ran " .. file
    assert.is_true(wait_capture(out, expanded))

    -- focus the terminal window (a non-file buffer)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "tarminal" then
        vim.api.nvim_set_current_win(win)
      end
    end

    -- a bare exec still prompts pre-filled with the expanded command
    -- accepting it must resend verbatim and not re-expand % against the
    -- terminal buffer which would send `echo ran <terminal name>`
    local seen_default
    local orig = vim.ui.input
    vim.ui.input = function(opts, on_confirm) ---@diagnostic disable-line: duplicate-set-field
      seen_default = opts.default
      on_confirm(opts.default)
    end
    tarminal.exec()
    vim.ui.input = orig
    assert.equals(expanded, seen_default)

    local resent = vim.wait(8000, function()
      local text = table.concat(vim.fn.readfile(out), "\n")
      local _, count = text:gsub(vim.pesc(expanded), "")
      return count >= 2
    end, 50)
    vim.fn.delete(out)
    vim.fn.delete(script)
    vim.fn.delete(file)
    assert.is_true(resent)
  end)

  it("prints no banner when banner = false", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({
      banner = false,
      park_on_error = false,
      follow_run = "none",
      time_runs = false,
      runners = { lua = "echo tarminal_ran; true" },
    })

    tarminal.run()
    local term_buf = find_term_buf()
    assert.is_not_nil(term_buf)

    -- the runner's own output is printed after any banner would have been
    local ran = vim.wait(8000, function()
      for _, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
        if l:find("tarminal_ran", 1, true) then
          return true
        end
      end
      return false
    end, 50)
    vim.fn.delete(file)
    assert.is_true(ran)
    for _, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
      assert.is_falsy(l:match("^====="))
    end
  end)

  it("keeps previous runs scrollable in the terminal", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({
      banner = true,
      clear_run = false,
      park_on_error = false,
      follow_run = "none",
      runners = { lua = "true" },
    })

    local term_buf

    tarminal.run()
    term_buf = find_term_buf()
    assert.is_not_nil(term_buf)
    assert.is_true(wait_run_finished(term_buf, 1))
    local first = banner_rows(term_buf)[1]

    tarminal.run()
    assert.is_true(vim.wait(4000, function()
      return #banner_rows(term_buf) == 2
    end, 50))
    -- the first run remains in the buffer while the window is scrolled to
    -- the second banner with no terminal output padding the viewport
    assert.equals(first, banner_rows(term_buf)[1])
    local find_win_for_buf = term.find_win_for_buf
    local term_win = find_win_for_buf(term_buf)
    assert.is_true(vim.wait(4000, function()
      return vim.api.nvim_win_call(term_win, function()
        return vim.fn.winsaveview().topline == banner_rows(term_buf)[2]
      end)
    end, 50))
    vim.fn.delete(file)
  end)

  it("wipes prior runs from the buffer when clear_run is set", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    -- the banner alone cannot tell the two runs apart so each run prints
    -- its own marker instead
    local opts = {
      banner = true,
      clear_run = true,
      park_on_error = false,
      follow_run = "none",
      time_runs = false,
      runners = { lua = "echo tarminal_first" },
    }
    tarminal.setup(opts)

    local term_buf
    local function printed(marker)
      for _, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
        if l:find(marker, 1, true) then
          return true
        end
      end
      return false
    end

    tarminal.run()
    term_buf = find_term_buf()
    assert.is_not_nil(term_buf)
    assert.is_true(wait_run_finished(term_buf, 1))
    assert.is_true(printed("tarminal_first"))

    opts.runners.lua = "echo tarminal_second"
    tarminal.setup(opts)
    tarminal.run()
    assert.is_true(vim.wait(4000, function()
      return printed("tarminal_second")
    end, 50))
    -- the scrollback clear ran ahead of the second banner so the first is gone
    assert.is_true(vim.wait(4000, function()
      return not printed("tarminal_first") and #banner_rows(term_buf) == 1
    end, 50))
    vim.fn.delete(file)
  end)

  -- headless nvim never reaches terminal-insert "t" mode so this exercises
  -- the immediate-pin path rather than the deferred flush
  -- it guards that insert-follow still lands the banner at the window top
  it("aligns the banner to the window top in insert-follow", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ banner = true, park_on_error = false, follow_run = "insert", runners = { lua = "true" } })

    tarminal.run()

    local term_buf = find_term_buf()
    assert.is_not_nil(term_buf)
    assert.is_true(wait_run_finished(term_buf, 1))

    local find_win_for_buf = term.find_win_for_buf
    local term_win = find_win_for_buf(term_buf)
    assert.is_true(vim.wait(4000, function()
      return vim.api.nvim_win_call(term_win, function()
        return vim.fn.winsaveview().topline == banner_rows(term_buf)[1]
      end)
    end, 50))
    vim.cmd("stopinsert")
    vim.fn.delete(file)
  end)

  it("keeps the last run when a later run has no configured runner", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    tarminal.run()
    local remembered = tarminal._last_run
    assert.equals(file, remembered.file)

    -- a file whose filetype has no runner must not overwrite the last run
    local other = vim.fn.tempname() .. ".xyz"
    vim.fn.writefile({ "nothing" }, other)
    vim.cmd("edit " .. vim.fn.fnameescape(other))
    vim.bo.filetype = "xyzlang"
    tarminal.run()

    assert.equals(remembered, tarminal._last_run)
    vim.fn.delete(file)
    vim.fn.delete(other)
  end)
end)
