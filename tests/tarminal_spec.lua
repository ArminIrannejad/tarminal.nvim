describe("tarminal", function()
  local tarminal

  local function get_upvalue(fn, wanted)
    for i = 1, 20 do
      local name, value = debug.getupvalue(fn, i)
      if not name then
        break
      end
      if name == wanted then
        return value
      end
    end
    error("missing upvalue: " .. wanted)
  end

  -- Wait until run `id`'s done marker is printed and the shell has taken
  -- the foreground back: only then will a follow-up run() not be refused
  -- by the busy guard (on slow CI the previous command is still running
  -- when two runs are issued back-to-back).
  local function wait_run_finished(term_buf, id)
    local token = ("DONE[%d]"):format(id)
    local term_busy = get_upvalue(tarminal.run, "term_busy")
    return vim.wait(8000, function()
      local seen = false
      for _, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
        if l:find(token, 1, true) then
          seen = true
          break
        end
      end
      return seen and not term_busy(term_buf)
    end, 50)
  end

  before_each(function()
    tarminal = require("tarminal")
    tarminal.setup()
    vim.cmd("enew!")
  end)

  after_each(function()
    tarminal.setup()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
        -- Force-deleting a terminal buffer while its job is alive with
        -- output in flight wedges the next terminal's refresh into a busy
        -- loop (nvim 0.12.4); stop the job and wait for it to exit first.
        local job = vim.b[buf].terminal_job_id
        if job then
          pcall(vim.fn.jobstop, job)
          pcall(vim.fn.jobwait, { job }, 1000)
        end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.cmd("silent! tabonly!")
  end)

  it("can be required", function()
    assert.is_table(tarminal)
  end)

  it("setup merges user options over defaults", function()
    tarminal.setup({ split_height = 20, runners = { rust = "cargo run" } })
    assert.equals(20, tarminal.config.split_height)
    assert.equals("cargo run", tarminal.config.runners.rust)
    -- untouched defaults survive the merge
    assert.equals("python", tarminal.config.runners.python)
    assert.equals("node", tarminal.config.runners.javascript)
    assert.equals("ipython", tarminal.config.repls.python)
  end)

  it("setup creates no keymaps", function()
    tarminal.setup()
    for _, mode in ipairs({ "n", "x", "t" }) do
      for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
        assert.is_falsy((map.desc or ""):lower():find("tarminal"))
      end
    end
  end)

  it("setup resets previous options", function()
    tarminal.setup({ split_height = 20 })
    tarminal.setup()
    assert.equals(12, tarminal.config.split_height)
  end)

  it("automatically compiles and runs compiler-based runners", function()
    tarminal.setup({ runners = { c = "clang -Wpedantic -Wall" } })
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local command = build({
      file = "/tmp/example.c",
      stem = "example",
      dir = "/tmp",
      ft = "c",
    })
    assert.equals("clang -Wpedantic -Wall '/tmp/example.c' -o 'example' && time ./'example'", command)
  end)

  it("appends the file to interpreted runners, timed by default", function()
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local ctx = { file = "/tmp/example.py", stem = "example", dir = "/tmp", ft = "python" }
    assert.equals("time python '/tmp/example.py'", build(ctx))

    tarminal.setup({ time_runs = false })
    assert.equals("python '/tmp/example.py'", build(ctx))
  end)

  it("times only the last command of a && chain", function()
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local ctx = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }
    assert.equals("cc '/tmp/example.c' -o 'example' && time ./'example'", build(ctx))

    tarminal.setup({ time_runs = false })
    assert.equals("cc '/tmp/example.c' -o 'example' && ./'example'", build(ctx))
  end)

  it("does not overwrite an extensionless source file when compiling", function()
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local command = build({ file = "/tmp/prog", stem = "prog", dir = "/tmp", ft = "c" })
    assert.equals("cc '/tmp/prog' -o 'prog.out' && time ./'prog.out'", command)
  end)

  it("recognizes compiler paths and versioned compiler names", function()
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local ctx = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }

    tarminal.setup({ runners = { c = "/usr/bin/clang-17 -Wall" } })
    assert.equals("/usr/bin/clang-17 -Wall '/tmp/example.c' -o 'example' && time ./'example'", build(ctx))
  end)

  it("runs a named file with its configured runner", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    tarminal.run()

    local term_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "tarminal" then
        term_buf = buf
      end
    end
    vim.fn.delete(file)
    assert.is_not_nil(term_buf)
    assert.equals(vim.fn.fnamemodify(file, ":h"), vim.b[term_buf].term_cwd)
  end)

  it("extracts an exact single-line visual selection", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdefgh" })
    vim.fn.setpos("'<", { 0, 1, 3, 0 })
    vim.fn.setpos("'>", { 0, 1, 5, 0 })
    local get_selection = get_upvalue(tarminal.send_selection, "get_visual_selection")
    assert.equals("cde", get_selection("v"))
  end)

  it("keeps a trailing multibyte character in a charwise selection", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcé" })
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 4, 0 }) -- é occupies bytes 4-5
    local get_selection = get_upvalue(tarminal.send_selection, "get_visual_selection")
    assert.equals("abcé", get_selection("v"))
  end)

  it("keeps multibyte characters inside a blockwise selection", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "xéy", "abc" })
    vim.fn.setpos("'<", { 0, 1, 2, 0 })
    vim.fn.setpos("'>", { 0, 2, 2, 0 })
    local get_selection = get_upvalue(tarminal.send_selection, "get_visual_selection")
    assert.equals("é\nb", get_selection("\22"))
  end)

  it("extracts an explicit line range", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
    local get_range = get_upvalue(tarminal.send_selection, "get_line_range")
    assert.equals("two\nthree", get_range(2, 3))
  end)

  it("uses the cell after a marker when the cursor is on the marker", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "print(1)",
      "# COMMAND ----------",
      "print(2)",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local get_cell = get_upvalue(tarminal.send_cell, "get_current_cell_text")
    assert.equals("print(2)\n", get_cell())
  end)

  it("does not treat a marker substring as a cell boundary", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "print(1)",
      'print("# COMMAND ----------")',
      "print(2)",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local get_cell = get_upvalue(tarminal.send_cell, "get_current_cell_text")
    assert.equals('print(1)\nprint("# COMMAND ----------")\nprint(2)\n', get_cell())
  end)

  it("parses error locations whose paths contain spaces", function()
    local dir = vim.fn.tempname() .. " space"
    local file = dir .. "/example file.lua"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "error()" }, file)

    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    local parsed_file, line, col = parse(file .. ":12:4: error", vim.api.nvim_get_current_buf())
    vim.fn.delete(dir, "rf")

    assert.equals(file, parsed_file)
    assert.equals(12, line)
    assert.equals(4, col)
  end)

  it("parses sbt-prefixed Scala error locations", function()
    local file = vim.fn.tempname() .. ".scala"
    vim.fn.writefile({ "object Main" }, file)

    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    local output = "[error] " .. file .. ":12:4: Not found: value broken"
    local parsed_file, line, col, span_start, span_end = parse(output, vim.api.nvim_get_current_buf())
    vim.fn.delete(file)

    assert.equals(file, parsed_file)
    assert.equals(12, line)
    assert.equals(4, col)
    assert.equals(output:find(file, 1, true), span_start)
    assert.equals(output:find(":12:4", 1, true) + 4, span_end)
  end)

  it("parses rustc error locations", function()
    local file = vim.fn.tempname() .. ".rs"
    vim.fn.writefile({ "fn main() {}" }, file)

    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    local output = " --> " .. file .. ":2:23"
    local parsed_file, line, col, span_start = parse(output, vim.api.nvim_get_current_buf())
    vim.fn.delete(file)

    assert.equals(file, parsed_file)
    assert.equals(2, line)
    assert.equals(23, col)
    assert.equals(output:find(file, 1, true), span_start)
  end)

  it("parses OCaml error locations", function()
    local file = vim.fn.tempname() .. ".ml"
    vim.fn.writefile({ "let answer = 42" }, file)

    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    local output = ('File "%s", line 1, characters 19-26:'):format(file)
    local parsed_file, line, col = parse(output, vim.api.nvim_get_current_buf())
    vim.fn.delete(file)

    assert.equals(file, parsed_file)
    assert.equals(1, line)
    assert.is_nil(col)
  end)

  it("parses C++ compiler error locations", function()
    local file = vim.fn.tempname() .. ".cpp"
    vim.fn.writefile({ "int main() {}" }, file)

    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    local output = file .. ":4:18: error: invalid conversion from 'const char*' to 'int'"
    local parsed_file, line, col = parse(output, vim.api.nvim_get_current_buf())
    vim.fn.delete(file)

    assert.equals(file, parsed_file)
    assert.equals(4, line)
    assert.equals(18, col)
  end)

  it("parses Node.js syntax error locations without a column", function()
    local file = vim.fn.tempname() .. ".js"
    vim.fn.writefile({ "function broken( {}" }, file)

    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    local parsed_file, line, col = parse(file .. ":2", vim.api.nvim_get_current_buf())
    vim.fn.delete(file)

    assert.equals(file, parsed_file)
    assert.equals(2, line)
    assert.is_nil(col)
  end)

  it("uses display width when rebuilding wrapped terminal lines", function()
    local logical_line_at = get_upvalue(tarminal.jump_to_error, "logical_line_at")
    local logical, first, last = logical_line_at({ "éé", "tail" }, 2, 4)
    assert.equals("tail", logical)
    assert.equals(2, first)
    assert.equals(2, last)
  end)

  it("toggle opens and closes the shell terminal split", function()
    tarminal.setup()
    local before = #vim.api.nvim_list_wins()
    tarminal.toggle()
    assert.equals(before + 1, #vim.api.nvim_list_wins())
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("terminal", vim.bo[buf].buftype)
    assert.equals("tarminal", vim.bo[buf].filetype)
    assert.is_truthy(vim.api.nvim_buf_get_name(buf):find("tarminal://shell", 1, true))
    tarminal.toggle()
    assert.equals(before, #vim.api.nvim_list_wins())
  end)

  it("shows and hides the shared terminal independently in each tab", function()
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local first_tab = vim.api.nvim_get_current_tabpage()
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(first_tab))

    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    tarminal.toggle()
    assert.equals(term_buf, vim.api.nvim_get_current_buf())
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(second_tab))
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(first_tab))

    tarminal.toggle()
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(second_tab))
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(first_tab))
  end)

  it("does not touch terminals it did not create", function()
    vim.cmd("terminal")
    local buf = vim.api.nvim_get_current_buf()
    assert.is_not.equals("tarminal", vim.bo[buf].filetype)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("fires FileType tarminal so users can add buffer-local keymaps", function()
    local mapped_buf
    local autocmd = vim.api.nvim_create_autocmd("FileType", {
      pattern = "tarminal",
      callback = function(ev)
        mapped_buf = ev.buf
        vim.keymap.set("n", "<CR>", tarminal.jump_to_error, { buffer = ev.buf, desc = "tarminal jump" })
      end,
    })
    tarminal.toggle()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_del_autocmd(autocmd)

    assert.equals(buf, mapped_buf)
    local found
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if map.desc == "tarminal jump" then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("clears stale error highlights when a new run starts", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    tarminal.run()
    local term_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "tarminal" then
        term_buf = buf
      end
    end
    assert.is_not_nil(term_buf)
    assert.is_true(wait_run_finished(term_buf, tarminal._run_id))

    -- a leftover highlight from a previous run, sitting on a line the
    -- terminal will rewrite in place
    local ns = get_upvalue(tarminal.run, "ns")
    vim.api.nvim_buf_set_extmark(term_buf, ns, 0, 0, { end_col = 1, hl_group = "TarminalError", strict = false })

    tarminal.run()
    vim.fn.delete(file)
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(term_buf, ns, 0, -1, {}))
  end)

  it("aborts the run when the file cannot be written", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    -- unsaved edits in a readonly buffer: update fails, the run must not
    -- silently execute the stale on-disk version
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
    tarminal.setup({ park_on_error = false, follow_run = "none", runners = { lua = "true" } })

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
    assert.is_true(wait_run_finished(vim.api.nvim_win_get_buf(term_win), tarminal._run_id))
    vim.api.nvim_set_current_win(term_win)
    tarminal.run()

    local saved = not vim.bo[src].modified
    vim.fn.delete(file)
    assert.is_true(saved)
  end)

  it("refuses to run while the terminal is busy with a command", function()
    -- foreground-job detection needs a shell with job control (a plain
    -- POSIX sh runs children in its own process group, where the busy
    -- guard degrades to a no-op) — pin bash rather than inherit $SHELL
    if vim.fn.executable("bash") == 0 then
      return
    end
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    -- a runner that keeps the shell's foreground occupied (generously long:
    -- it must still be running when the second run() is attempted, even on
    -- a slow CI runner; after_each kills the shell well before it expires)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ "sleep 30" }, script)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({
      park_on_error = false,
      follow_run = "none",
      shell = "bash",
      runners = { lua = "sh " .. script },
    })

    tarminal.run()
    local first_id = tarminal._run_id

    local term_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "tarminal" then
        term_buf = buf
      end
    end
    assert.is_not_nil(term_buf)
    local term_busy = get_upvalue(tarminal.run, "term_busy")
    local busy = vim.wait(8000, function()
      return term_busy(term_buf) == true
    end, 50)
    assert.is_true(busy)

    tarminal.run()
    assert.equals(first_id, tarminal._run_id)
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)

  it("stops the error watcher when the run completes", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ follow_run = "none", runners = { lua = "true" } })

    tarminal.run()
    assert.is_not_nil(tarminal._watch_timer)
    -- well under the watcher's silence timeout: only the done marker can
    -- have stopped it this quickly
    local stopped = vim.wait(6000, function()
      return tarminal._watch_timer == nil
    end, 50)
    vim.fn.delete(file)
    assert.is_true(stopped)
  end)

  it("highlights error locations printed by a run", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    -- a runner that prints an error location pointing at the file itself
    tarminal.setup({
      follow_run = "none",
      time_runs = false,
      runners = { lua = [[printf '%s:1:1: boom\n']] },
    })

    tarminal.run()
    local term_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "tarminal" then
        term_buf = buf
      end
    end
    assert.is_not_nil(term_buf)

    local ns = get_upvalue(tarminal.run, "ns")
    local highlighted = vim.wait(6000, function()
      return #vim.api.nvim_buf_get_extmarks(term_buf, ns, 0, -1, {}) > 0
    end, 50)
    local stopped = vim.wait(6000, function()
      return tarminal._watch_timer == nil
    end, 50)
    vim.fn.delete(file)
    assert.is_true(highlighted)
    assert.is_true(stopped)
  end)

  it("keeps previous runs scrollable in the terminal", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    local term_buf
    local function has_banner(token)
      for _, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
        if l:match("^=====") and l:find(token, 1, true) then
          return true
        end
      end
      return false
    end

    tarminal.run()
    local first = ("RUN[%d]"):format(tarminal._run_id)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "tarminal" then
        term_buf = buf
      end
    end
    assert.is_not_nil(term_buf)
    assert.is_true(wait_run_finished(term_buf, tarminal._run_id))
    assert.is_true(has_banner(first))

    tarminal.run()
    local second = ("RUN[%d]"):format(tarminal._run_id)
    assert.is_true(vim.wait(4000, function()
      return has_banner(second)
    end, 50))
    -- the first run's banner must survive the second run's screen push
    assert.is_true(has_banner(first))
    vim.fn.delete(file)
  end)

  it("refuses error navigation outside a terminal buffer", function()
    vim.fn.setqflist({})
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int x;" }, file)
    -- a line that would parse as an error location if this were a terminal
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { file .. ":1:1: fake error" })
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()

    tarminal.errors_to_quickfix()
    -- the code window must not be mistaken for the terminal and closed
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.equals(0, #vim.fn.getqflist())

    tarminal.jump_to_error()
    tarminal.next_error()
    tarminal.prev_error()
    assert.equals(win, vim.api.nvim_get_current_win())

    vim.cmd("only")
    vim.fn.delete(file)
  end)

  it("navigates and jumps between error locations, repeatedly", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int a;", "int b;", "int c;" }, file)

    -- Run a script that prints two error locations instead of an
    -- interactive shell: no prompt and no command echo, so the terminal
    -- content is identical whatever sh the machine has (bash, dash, ...).
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({
      ("printf '%%s:1:1: aaa\\n%%s:2:2: bbb\\n' %s %s"):format(file, file),
      "sleep 10",
    }, script)
    tarminal.setup({ shell = "sh " .. script })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":2:2: bbb", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    vim.api.nvim_win_set_cursor(term_win, { vim.api.nvim_buf_line_count(term_buf), 0 })
    tarminal.prev_error()
    local line = vim.api.nvim_get_current_line()
    assert.is_truthy(line:find(":2:2: bbb", 1, true))

    tarminal.jump_to_error()
    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 1 }, vim.api.nvim_win_get_cursor(0))

    -- back in the terminal, navigation still works after the jump; start
    -- from the bottom again rather than assuming the cursor was preserved
    vim.api.nvim_set_current_win(term_win)
    vim.api.nvim_win_set_cursor(term_win, { vim.api.nvim_buf_line_count(term_buf), 0 })
    tarminal.prev_error()
    tarminal.prev_error()
    assert.is_truthy(vim.api.nvim_get_current_line():find(":1:1: aaa", 1, true))
    tarminal.next_error()
    assert.is_truthy(vim.api.nvim_get_current_line():find(":2:2: bbb", 1, true))

    tarminal.jump_to_error()
    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 1 }, vim.api.nvim_win_get_cursor(0))
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)
end)
