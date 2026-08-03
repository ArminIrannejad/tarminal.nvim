local helpers = require("tests.helpers")

describe("tarminal errors", function()
  local tarminal = require("tarminal")
  local errors = require("tarminal.errors")
  local platform = require("tarminal.platform")

  local wait_run_finished = helpers.wait_run_finished
  local find_term_buf = helpers.find_term_buf

  helpers.hooks()

  it("parses error locations whose paths contain spaces", function()
    local dir = vim.fn.tempname() .. " space"
    local file = dir .. "/example file.lua"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "error()" }, file)

    local parse = errors.parse_error_line
    local parsed_file, line, col = parse(file .. ":12:4: error", vim.api.nvim_get_current_buf())
    vim.fn.delete(dir, "rf")

    assert.equals(file, parsed_file)
    assert.equals(12, line)
    assert.equals(4, col)
  end)

  it("parses sbt-prefixed Scala error locations", function()
    local file = vim.fn.tempname() .. ".scala"
    vim.fn.writefile({ "object Main" }, file)

    local parse = errors.parse_error_line
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

    local parse = errors.parse_error_line
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

    local parse = errors.parse_error_line
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

    local parse = errors.parse_error_line
    local output = file .. ":4:18: error: invalid conversion from 'const char*' to 'int'"
    local parsed_file, line, col = parse(output, vim.api.nvim_get_current_buf())
    vim.fn.delete(file)

    assert.equals(file, parsed_file)
    assert.equals(4, line)
    assert.equals(18, col)
  end)

  it("parses error locations whose paths contain parentheses", function()
    local dir = vim.fn.tempname()
    local file = dir .. "/report(audit).c"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "int main() {}" }, file)

    local parse = errors.parse_error_line
    local parsed_file, line, col = parse(file .. ":1:2: error", vim.api.nvim_get_current_buf())
    vim.fn.delete(dir, "rf")

    assert.equals(file, parsed_file)
    assert.equals(1, line)
    assert.equals(2, col)
  end)

  it("unwraps a path the message encloses in parentheses (V8 stack trace)", function()
    local file = vim.fn.tempname() .. ".js"
    vim.fn.writefile({ "throw new Error()" }, file)

    local parse = errors.parse_error_line
    local output = "    at Object.<anonymous> (" .. file .. ":1:7)"
    local parsed_file, line, col, span_start = parse(output, vim.api.nvim_get_current_buf())
    vim.fn.delete(file)

    assert.equals(file, parsed_file)
    assert.equals(1, line)
    assert.equals(7, col)
    -- the highlight span starts at the path past the wrapping "("
    assert.equals(output:find(file, 1, true), span_start)
  end)

  it("unwraps a path glued to a prefix by a bracket (Java stack frame)", function()
    local dir = vim.fn.tempname()
    local file = dir .. "/Main.java"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "class Main {}" }, file)

    local parse = errors.parse_error_line
    -- the source name is glued to the frame's method with no space before "("
    local output = "\tat pkg.Main.run(" .. file .. ":123)"
    local parsed_file, line, col, span_start = parse(output, vim.api.nvim_get_current_buf())
    vim.fn.delete(dir, "rf")

    assert.equals(file, parsed_file)
    assert.equals(123, line)
    assert.is_nil(col)
    -- the highlight span starts at the path past the glued "run("
    assert.equals(output:find(file, 1, true), span_start)
  end)

  it("parses Node.js syntax error locations without a column", function()
    local file = vim.fn.tempname() .. ".js"
    vim.fn.writefile({ "function broken( {}" }, file)

    local parse = errors.parse_error_line
    local parsed_file, line, col = parse(file .. ":2", vim.api.nvim_get_current_buf())
    vim.fn.delete(file)

    assert.equals(file, parsed_file)
    assert.equals(2, line)
    assert.is_nil(col)
  end)

  it("classifies severity from the error pattern's type capture", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main() {}" }, file)
    local parse = errors.parse_error_line
    local buf = vim.api.nvim_get_current_buf()

    local function sev(text)
      return select(6, parse(text, buf))
    end
    assert.equals(2, sev(file .. ":1:1: error: boom"))
    assert.equals(1, sev(file .. ":1:1: warning: hmm"))
    assert.equals(0, sev(file .. ":1:1: note: fyi"))
    -- a bare location with no severity word is treated as an error
    assert.equals(2, sev(file .. ":1:1"))
    vim.fn.delete(file)
  end)

  it("keeps severity when the fallback parser handles a path with spaces", function()
    -- the space defeats the built-in patterns and forces the fallback parser
    local file = vim.fn.tempname() .. " sp.c"
    vim.fn.writefile({ "int main() {}" }, file)
    local parse = errors.parse_error_line
    local buf = vim.api.nvim_get_current_buf()
    assert.equals(file, (parse(file .. ":1:1: warning", buf)))
    local function sev(text)
      return select(6, parse(text, buf))
    end
    assert.equals(1, sev(file .. ":1:1: warning: hmm"))
    assert.equals(0, sev(file .. ":1:1: note"))
    assert.equals(2, sev(file .. ":1:1"))
    vim.fn.delete(file)
  end)

  it("matches a user-added pattern and trusts it with resolve = false", function()
    tarminal.setup({
      error_patterns = {
        { pattern = "at (%S+) line (%d+)", file = 1, lnum = 2, resolve = false },
      },
    })
    local parse = errors.parse_error_line
    -- the path need not exist on disk when the pattern sets resolve = false
    local file, line = parse("Died at /no/such/script.pl line 42.", vim.api.nvim_get_current_buf())
    assert.equals("/no/such/script.pl", file)
    assert.equals(42, line)
  end)

  it("prepends user error_patterns to the built-ins", function()
    tarminal.setup({ error_patterns = { { pattern = "X(%d+)", file = 1 } } })
    local pats = tarminal.config.error_patterns
    assert.equals("X(%d+)", pats[1].pattern)
    -- the built-ins survive after the user's entry
    assert.equals('File "([^"]+)", line (%d+)', pats[#pats].pattern)
  end)

  it("uses display width when rebuilding wrapped terminal lines", function()
    local logical_line_at = errors.logical_line_at
    local logical, first, last = logical_line_at({ "éé", "tail" }, 2, 4)
    assert.equals("tail", logical)
    assert.equals(2, first)
    assert.equals(2, last)
  end)

  it("does not glue an exact-width line onto the diagnostic below it", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main() {}" }, file)
    local buf = vim.api.nvim_get_current_buf()
    local width = 20
    -- a line that happens to exactly fill the width looks like a soft wrap
    local lines = { string.rep("x", width), file .. ":2:1: error" }
    local first, last, f = errors.scan_logical_at(lines, 2, width, buf)
    assert.equals(file, f)
    assert.equals(2, first)
    assert.equals(2, last)
    vim.fn.delete(file)
  end)

  it("keeps a scan bounded so a walking loop always advances", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main() {}" }, file)
    local buf = vim.api.nvim_get_current_buf()
    local diag = file .. ":2:1: error"
    local width = vim.fn.strdisplaywidth(diag) + 4
    local lines = {
      string.rep("x", width),
      diag .. string.rep(" ", width - vim.fn.strdisplaywidth(diag)),
      "tail",
    }
    -- without the bound the match on row 2 is returned again from row 3
    local first, last, f = errors.scan_logical_at(lines, 3, width, buf, 3)
    assert.is_true(last >= 3)
    assert.is_nil(f)
    local rfirst = errors.scan_logical_at(lines, 1, width, buf, nil, 1)
    assert.is_true(rfirst <= 1)
    -- unbounded still finds the row under the cursor's logical line
    local _, _, unbounded = errors.scan_logical_at(lines, 3, width, buf)
    assert.equals(file, unbounded)
    assert.equals(1, first)
    vim.fn.delete(file)
  end)

  it("clears stale error highlights when a new run starts", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ banner = true, park_on_error = false, follow_run = "none", runners = { lua = "true" } })

    tarminal.run()
    local term_buf = find_term_buf()
    assert.is_not_nil(term_buf)
    assert.is_true(wait_run_finished(term_buf, 1))

    -- a leftover highlight from a previous run sitting on a line the
    -- terminal will rewrite in place
    local ns = errors.ns
    vim.api.nvim_buf_set_extmark(term_buf, ns, 0, 0, { end_col = 1, hl_group = "TarminalError", strict = false })

    tarminal.run()
    vim.fn.delete(file)
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(term_buf, ns, 0, -1, {}))
  end)

  it("keeps watching while the shell still has a child", function()
    -- a shell busy in a builtin owns the foreground and so looks idle
    local buf = vim.api.nvim_create_buf(false, true)
    local term_busy, shell_has_child = platform.term_busy, platform.shell_has_child
    platform.term_busy = function()
      return false
    end
    platform.shell_has_child = function()
      return true
    end

    errors.watch_run_output(buf, nil, 0, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "output" })
    local stopped_early = vim.wait(2000, function()
      return tarminal._watch_timer == nil
    end, 50)

    platform.shell_has_child = function()
      return false
    end
    local stopped = vim.wait(4000, function()
      return tarminal._watch_timer == nil
    end, 50)

    platform.term_busy, platform.shell_has_child = term_busy, shell_has_child
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_false(stopped_early)
    assert.is_true(stopped)
  end)

  it("stops the error watcher when the run completes", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ follow_run = "none", runners = { lua = "true" } })

    tarminal.run()
    assert.is_not_nil(tarminal._watch_timer)
    -- well under the watcher's silence timeout so only the done marker
    -- can have stopped it this quickly
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
    local term_buf = find_term_buf()
    assert.is_not_nil(term_buf)

    local ns = errors.ns
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

  it("highlights errors and stops the watcher without a banner", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({
      banner = false,
      follow_run = "none",
      time_runs = false,
      runners = { lua = [[printf '%s:1:1: boom\n']] },
    })

    tarminal.run()
    local term_buf = find_term_buf()
    assert.is_not_nil(term_buf)

    local ns = errors.ns
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

  it("collects only locations at or above error_threshold into quickfix", function()
    vim.fn.setqflist({})
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    -- a script with no prompt or command echo prints a warning then an error
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({
      ("printf '%%s:1:1: warning: w\\n%%s:2:1: error: e\\n' %s %s"):format(file, file),
      "sleep 10",
    }, script)
    tarminal.setup({
      shell = "sh " .. script,
      error_threshold = 2, -- errors only
      quickfix = { open = false, close_terminal = false },
    })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":2:1: error", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    tarminal.errors_to_quickfix()
    local qf = vim.fn.getqflist()
    vim.fn.delete(file)
    vim.fn.delete(script)
    -- the warning is below threshold so only the error is collected
    assert.equals(1, #qf)
    assert.equals(2, qf[1].lnum)
    assert.equals("E", qf[1].type)
  end)

  it("collects an error that follows a width-filling output line", function()
    vim.fn.setqflist({})
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int a;" }, file)
    -- an output line as wide as the terminal looks like a wrapped first row
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({
      ("printf '%%s\\n' %s"):format(string.rep("x", vim.o.columns)),
      ("printf '%%s:1:1: error: e\\n' %s"):format(file),
      "sleep 10",
    }, script)
    tarminal.setup({ shell = "sh " .. script, quickfix = { open = false, close_terminal = false } })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    assert.equals(vim.o.columns, vim.api.nvim_win_get_width(0))

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":1:1: error", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    tarminal.errors_to_quickfix()
    local qf = vim.fn.getqflist()
    vim.fn.delete(file)
    vim.fn.delete(script)
    assert.equals(1, #qf)
    assert.equals(1, qf[1].lnum)
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

  it("clamps a line 0 location to the first line when jumping", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    -- linkers emit locations with line 0
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({
      ("printf '%%s:0: undefined reference to main\\n' %s"):format(file),
      "sleep 10",
    }, script)
    tarminal.setup({ shell = "sh " .. script })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":0:", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    vim.api.nvim_win_set_cursor(term_win, { 1, 0 })
    tarminal.jump_to_error()
    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)

  it("navigates and jumps between error locations, repeatedly", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;", "int c;" }, file)

    -- run a script that prints two error locations instead of an
    -- interactive shell
    -- no prompt and no command echo so the terminal content is identical
    -- whatever sh the machine has
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

    -- back in the terminal navigation still works after the jump
    -- start from the bottom rather than assume the cursor was preserved
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

  it("hides the terminal when closing it for quickfix as the only window", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int a;" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ ("printf '%%s:1:1: error\\n' %s"):format(file), "sleep 10" }, script)
    tarminal.setup({ shell = "sh " .. script, quickfix = { open = true, close_terminal = true } })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    vim.cmd("wincmd o") -- the terminal is the only window
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":1:1", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    tarminal.errors_to_quickfix()

    -- the terminal is no longer displayed and the quickfix window took over
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      assert.is_not.equals(term_buf, vim.api.nvim_win_get_buf(win))
    end
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)

  it("closes the terminal after a jump when close_on_jump is set", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ ("printf '%%s:2:1: error: e\\n' %s"):format(file), "sleep 10" }, script)
    tarminal.setup({ shell = "sh " .. script, close_on_jump = true })

    vim.cmd("enew") -- a code window for the jump to land in
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":2:1", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    vim.api.nvim_win_set_cursor(term_win, { 1, 0 })
    tarminal.jump_to_error()

    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.is_false(vim.api.nvim_win_is_valid(term_win))
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)

  it("leaves the terminal open when close_on_jump finds no location", function()
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ "printf 'no location here\\n'", "sleep 10" }, script)
    tarminal.setup({ shell = "sh " .. script, close_on_jump = true })

    vim.cmd("enew")
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find("no location here", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    vim.api.nvim_win_set_cursor(term_win, { 1, 0 })
    tarminal.jump_to_error()

    assert.is_true(vim.api.nvim_win_is_valid(term_win))
    assert.equals(term_buf, vim.api.nvim_win_get_buf(term_win))
    vim.fn.delete(script)
  end)

  it("reuses a non-file window instead of splitting a third one in", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ ("printf '%%s:2:1: error: e\\n' %s"):format(file), "sleep 10" }, script)
    tarminal.setup({ shell = "sh " .. script })

    -- an oil-style window that is the only code window and not a file buffer
    vim.cmd("enew")
    vim.cmd("wincmd o")
    vim.bo.buftype = "acwrite"
    local code_win = vim.api.nvim_get_current_win()
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":2:1", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    vim.api.nvim_win_set_cursor(term_win, { 1, 0 })
    tarminal.jump_to_error()

    assert.equals(code_win, vim.api.nvim_get_current_win())
    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)

  it("splits rather than taking over a quickfix window", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ ("printf '%%s:2:1: error: e\\n' %s"):format(file), "sleep 10" }, script)
    tarminal.setup({ shell = "sh " .. script })

    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()
    vim.cmd("wincmd o") -- terminal + quickfix are the only windows
    vim.fn.setqflist({}, " ", { items = { { filename = file, lnum = 1 } } })
    vim.cmd("botright copen")
    local qf_win = vim.api.nvim_get_current_win()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":2:1", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    vim.api.nvim_set_current_win(term_win)
    vim.api.nvim_win_set_cursor(term_win, { 1, 0 })
    tarminal.jump_to_error()

    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.is_not.equals(qf_win, vim.api.nvim_get_current_win())
    assert.equals("quickfix", vim.bo[vim.api.nvim_win_get_buf(qf_win)].buftype)
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)

  it("refuses error navigation in a terminal it did not create", function()
    vim.fn.setqflist({})
    vim.cmd("terminal")
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    assert.is_not.equals("tarminal", vim.bo[buf].filetype)

    tarminal.errors_to_quickfix()
    tarminal.jump_to_error()
    tarminal.next_error()

    -- the foreign terminal stays open and nothing is collected from it
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.equals(buf, vim.api.nvim_win_get_buf(win))
    assert.equals(0, #vim.fn.getqflist())
  end)

  it("jumps to a file-only location without a line number", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".txt"
    vim.fn.writefile({ "hello", "world" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ ("printf 'see %%s\\n' %s"):format(file), "sleep 10" }, script)
    tarminal.setup({
      shell = "sh " .. script,
      error_patterns = { { pattern = "see (%S+)", file = 1, resolve = false } },
    })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()

    local target
    local seen = vim.wait(4000, function()
      for i, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
        if l:find("see " .. file, 1, true) then
          target = i
          return true
        end
      end
      return false
    end, 50)
    assert.is_true(seen)

    vim.api.nvim_win_set_cursor(term_win, { target, 0 })
    -- a pattern with no line number used to crash on math.max(nil, 1)
    local ok = pcall(tarminal.jump_to_error)

    assert.is_true(ok)
    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)
end)
