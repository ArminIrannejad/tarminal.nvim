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

  it("resolves a path printed relative to a root above the terminal's directory", function()
    local root = vim.fn.resolve(vim.fn.tempname())
    local project = root .. "/project"
    local member = project .. "/crates/foo"
    vim.fn.mkdir(member .. "/src", "p")
    vim.fn.mkdir(project .. "/.git", "p")
    vim.fn.mkdir(root .. "/shared", "p")
    vim.fn.writefile({ "fn main() {}" }, member .. "/src/main.rs")
    vim.fn.writefile({ "" }, project .. "/lib.rs")
    vim.fn.writefile({ "wrong" }, root .. "/shared/outside.c")
    local buf = vim.api.nvim_create_buf(false, true)
    -- cargo runs in the workspace member but prints paths from the workspace root
    vim.b[buf].term_cwd = member

    local parse = errors.parse_error_line
    local file, line, col = parse(" --> crates/foo/src/main.rs:2:18", buf)
    -- a bare name is never looked for above and lookup stops at the project root
    local bare = parse("lib.rs:1:1: error", buf)
    local outside = parse("shared/outside.c:1:1: error", buf)
    -- nor is a symlinked or slash-suffixed $HOME crossed
    local home_link = root .. "/home"
    assert(vim.uv.fs_symlink(project .. "/crates", home_link, { dir = true }))
    local home = vim.env.HOME
    vim.env.HOME = home_link .. "/"
    local ok, capped = pcall(parse, " --> crates/foo/src/main.rs:2:18", buf)
    vim.env.HOME = home
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, "rf")
    if not ok then
      error(capped, 0)
    end

    assert.equals(project .. "/crates/foo/src/main.rs", file)
    assert.equals(2, line)
    assert.equals(18, col)
    assert.is_nil(bare)
    assert.is_nil(outside)
    assert.is_nil(capped)
  end)

  it("resolves paths against the directory make or ninja entered", function()
    local root = vim.fn.resolve(vim.fn.tempname())
    for _, d in ipairs({ "sub/build", "src" }) do
      vim.fn.mkdir(root .. "/" .. d, "p")
    end
    vim.fn.writefile({ "int a;" }, root .. "/sub/a.c")
    vim.fn.writefile({ "int nested;" }, root .. "/sub/build/a.c")
    vim.fn.writefile({ "int b;" }, root .. "/src/b.c")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].term_cwd = root
    local width = 32
    local lines = {}
    local function add(line)
      repeat
        lines[#lines + 1] = line:sub(1, width)
        line = line:sub(width + 1)
      until line == ""
    end

    -- the announcement wraps, then ninja nests under the directory make entered
    add("make[1]: Entering directory '" .. root .. "/sub'")
    add("a.c:1:2: error: x")
    local entered_row = #lines
    add("ninja: Entering directory `build'")
    add("a.c:1:2: error: nested")
    local nested_row = #lines
    -- make names the directory it leaves, so nested ninja state must leave too
    add("make[1]: Leaving directory '" .. root .. "/sub'")
    add("a.c:1:2: error: y")
    local left_row = #lines
    add("make[1]: Entering directory '" .. root .. "/sub'")
    add("===== PROGRAM RUN state =====")
    add("a.c:1:2: error: still entered")
    local loose_banner_row = #lines
    add("===== RUN: 12:00:00 =====")
    add("a.c:1:2: error: next run")
    local next_run_row = #lines

    local dirs = errors.dir_map(lines, 1, buf, width)
    local function at(row)
      return select(3, errors.scan_logical_at(lines, row, width, buf, nil, nil, nil, dirs))
    end
    local entered, nested, left = at(entered_row), at(nested_row), at(left_row)
    local loose_banner, next_run = at(loose_banner_row), at(next_run_row)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, "rf")

    assert.equals(root .. "/sub/a.c", entered)
    assert.equals(root .. "/sub/build/a.c", nested)
    assert.is_nil(left)
    assert.equals(root .. "/sub/a.c", loose_banner)
    -- a new run starts outside any directory the last one entered
    assert.is_nil(next_run)
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

  it("resolves the output once however often the watcher rescans it", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local term_busy, term_cwd = platform.term_busy, platform.term_cwd
    local lookups = 0
    platform.term_busy = function()
      return true
    end
    -- every relative path a scan resolves asks for the terminal's cwd
    platform.term_cwd = function()
      lookups = lookups + 1
      return "/nonexistent"
    end

    local ok, err = pcall(function()
      errors.watch_run_output(buf, nil, 0, true)
      local out = {}
      for i = 1, 50 do
        out[i] = ("missing%d/file.c:%d:1: error"):format(i, i)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
      vim.wait(2000, function()
        return lookups > 0
      end, 20)
      vim.wait(400)
      local first = lookups
      -- every tick rescans the whole run but the new lines hold no paths
      for i = 1, 3 do
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "tail " .. i })
        vim.wait(400)
      end
      assert.is_true(first >= 50)
      assert.equals(first, lookups)

      -- scrollback can discard unique lines during a banner-less long run;
      -- a later tick drops their line and path cache entries too
      for i = 1, 1001 do
        out[i] = ("old%d/file.c:%d:1: error"):format(i, i)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
      vim.wait(2000, function()
        return lookups > first + 1000
      end, 20)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "tail only" })
      vim.wait(400)
      local pruned = lookups
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { out[1] })
      assert.is_true(vim.wait(2000, function()
        return lookups > pruned
      end, 20))
    end)

    platform.term_busy, platform.term_cwd = term_busy, term_cwd
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if not ok then
      error(err, 0)
    end
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

  it("replaces its own quickfix list instead of stacking onto it", function()
    local stale = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int stale;" }, stale)
    vim.fn.setqflist({}, " ", { title = "tarminal errors", items = { { filename = stale, lnum = 1 } } })
    local depth = vim.fn.getqflist({ nr = "$" }).nr

    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ ("printf '%%s:2:1: error: e\\n' %s"):format(file), "sleep 10" }, script)
    tarminal.setup({ shell = "sh " .. script, quickfix = { open = false, close_terminal = false } })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":2:1: error", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    tarminal.errors_to_quickfix()
    local qf = vim.fn.getqflist()
    vim.fn.delete(stale)
    vim.fn.delete(file)
    vim.fn.delete(script)
    assert.equals(1, #qf)
    assert.equals(2, qf[1].lnum)
    assert.equals(depth, vim.fn.getqflist({ nr = "$" }).nr)
  end)

  it("clears its own quickfix list when a run has no errors", function()
    local stale = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int stale;" }, stale)
    vim.fn.setqflist({}, " ", { title = "tarminal errors", items = { { filename = stale, lnum = 1 } } })

    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ "printf 'all good\\n'", "sleep 10" }, script)
    tarminal.setup({ shell = "sh " .. script, quickfix = { open = false, close_terminal = false } })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find("all good", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    tarminal.errors_to_quickfix()
    local qf = vim.fn.getqflist()
    vim.fn.delete(stale)
    vim.fn.delete(script)
    assert.equals(0, #qf)
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

  it("hides a floating terminal after a jump so the code is not under it", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ ("printf '%%s:2:1: error: e\\n' %s"):format(file), "sleep 10" }, script)
    tarminal.setup({ shell = "sh " .. script, layout = "float" })

    vim.cmd("enew")
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
    assert.is_false(vim.api.nvim_win_is_valid(term_win))
    tarminal.toggle()
    assert.equals(term_buf, vim.api.nvim_get_current_buf())
    assert.equals("editor", vim.api.nvim_win_get_config(0).relative)
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

  it("keeps navigating when the user changes the terminal filetype", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ ("printf '%%s:2:1: error: e\\n' %s"):format(file), "sleep 10" }, script)
    tarminal.setup({ shell = "sh " .. script })

    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    vim.bo[term_buf].filetype = "myterm"
    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":2:1", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    tarminal.jump_to_error()

    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    vim.fn.delete(file)
    vim.fn.delete(script)
  end)

  it("publishes run errors as diagnostics and clears them on the next run", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;", "int c;" }, file)
    local errors = require("tarminal.errors")
    tarminal.setup({ diagnostics = true, follow_run = "none" })

    tarminal.exec(("printf '%%s:2:5: error: bad thing\\n%%s:3:1: warning: meh\\n' %s %s"):format(file, file), true)
    local buf = vim.fn.bufadd(file)
    local got = vim.wait(8000, function()
      return #vim.diagnostic.get(buf, { namespace = errors.diag_ns }) == 2
    end, 50)
    assert.is_true(got)

    local diags = vim.diagnostic.get(buf, { namespace = errors.diag_ns })
    table.sort(diags, function(a, b)
      return a.lnum < b.lnum
    end)
    assert.same({ 1, 4 }, { diags[1].lnum, diags[1].col })
    assert.equals("bad thing", diags[1].message)
    assert.equals(vim.diagnostic.severity.ERROR, diags[1].severity)
    assert.equals(vim.diagnostic.severity.WARN, diags[2].severity)

    helpers.wait_run_finished(helpers.find_term_buf(), 1)
    tarminal.exec("true", true)
    assert.equals(0, #vim.diagnostic.get(buf, { namespace = errors.diag_ns }))
    vim.fn.delete(file)
  end)

  local function run_diags(file, script_lines)
    local errors = require("tarminal.errors")
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile(script_lines, script)
    vim.cmd("badd " .. vim.fn.fnameescape(file))
    local buf = vim.fn.bufnr(file)
    tarminal.setup({ diagnostics = true, follow_run = "none" })
    tarminal.exec("sh " .. script, true)
    vim.wait(8000, function()
      return #vim.diagnostic.get(buf, { namespace = errors.diag_ns }) > 0
    end, 50)
    helpers.wait_run_finished(helpers.find_term_buf(), 1)
    vim.fn.delete(script)
    return vim.diagnostic.get(buf, { namespace = errors.diag_ns }), buf
  end

  it("takes a rustc message from the line above its location", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".rs"
    vim.fn.writefile({ "fn main() {", "    x;", "}" }, file)
    local diags = run_diags(file, {
      "printf 'error[E0425]: cannot find value x in this scope\\n'",
      ("printf '  --> %s:2:5\\n'"):format(file),
    })
    vim.fn.delete(file)
    assert.equals(1, #diags)
    assert.equals("error[E0425]: cannot find value x in this scope", diags[1].message)
  end)

  it("gives python frames the exception their traceback ends in", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".py"
    vim.fn.writefile({ "def f():", "    raise ValueError('bad')", "f()" }, file)
    local diags = run_diags(file, {
      "printf 'Traceback (most recent call last):\\n'",
      ("printf '  File \"%s\", line 3, in <module>\\n    f()\\n'"):format(file),
      ("printf '  File \"%s\", line 2, in f\\n    raise\\n'"):format(file),
      "printf 'ValueError: bad\\n'",
    })
    vim.fn.delete(file)
    table.sort(diags, function(a, b)
      return a.lnum < b.lnum
    end)
    assert.equals("ValueError: bad (in f)", diags[1].message)
    assert.equals("ValueError: bad (in <module>)", diags[2].message)
  end)

  it("does not take the banner as a message", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local diags = run_diags(file, { ("printf '%%s:2:\\n' %s"):format(file) })
    vim.fn.delete(file)
    assert.equals(file .. ":2:", diags[1].message)
  end)

  it("republishes only when the errors change", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local errors = require("tarminal.errors")
    vim.cmd("badd " .. vim.fn.fnameescape(file))
    local buf = vim.fn.bufnr(file)
    local count = 0
    local id = vim.api.nvim_create_autocmd("DiagnosticChanged", {
      callback = function(ev)
        if ev.buf == buf then
          count = count + 1
        end
      end,
    })
    tarminal.setup({ diagnostics = true, follow_run = "none" })
    tarminal.exec(
      ("printf '%%s:2:1: error: e\\n' %s; for i in 1 2 3 4 5; do echo noise $i; sleep 0.3; done"):format(file),
      true
    )
    assert.is_true(vim.wait(8000, function()
      return #vim.diagnostic.get(buf, { namespace = errors.diag_ns }) == 1
    end, 20))
    local after_first = count
    assert.is_true(helpers.wait_run_finished(helpers.find_term_buf(), 1, "noise 5"))
    vim.api.nvim_del_autocmd(id)
    vim.fn.delete(file)
    assert.equals(after_first, count)
  end)

  it("holds diagnostics for an unopened file until it is read", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local errors = require("tarminal.errors")
    tarminal.setup({ diagnostics = true, follow_run = "none" })
    tarminal.exec(("printf '%%s:2:1: error: late\\n' %s"):format(file), true)
    assert.is_true(helpers.wait_run_finished(helpers.find_term_buf(), 1))
    vim.wait(1000, function()
      return false
    end, 50)
    assert.equals(-1, vim.fn.bufnr(file))

    vim.cmd("edit " .. vim.fn.fnameescape(file))
    local diags = vim.diagnostic.get(0, { namespace = errors.diag_ns })
    vim.fn.delete(file)
    assert.equals(1, #diags)
    assert.equals("late", diags[1].message)
  end)

  it("publishes no diagnostics by default", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local errors = require("tarminal.errors")
    tarminal.setup({ follow_run = "none" })

    tarminal.exec(("printf '%%s:2:1: error: e\\n' %s"):format(file), true)
    local term_buf = helpers.find_term_buf()
    assert.is_true(vim.wait(8000, function()
      return #vim.api.nvim_buf_get_extmarks(term_buf, errors.ns, 0, -1, {}) > 0
    end, 50))
    assert.equals(0, #vim.diagnostic.get(vim.fn.bufadd(file), { namespace = errors.diag_ns }))
    vim.fn.delete(file)
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

  it("navigates errors in any terminal when any_terminal is set", function()
    local file = vim.fn.resolve(vim.fn.tempname()) .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ ("printf '%%s:2:1: error: e\\n' %s"):format(file), "sleep 10" }, script)
    tarminal.setup({ any_terminal = true, quickfix = { open = false, close_terminal = false } })

    vim.cmd("split | terminal sh " .. vim.fn.fnameescape(script))
    local term_buf = vim.api.nvim_get_current_buf()
    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find(file .. ":2:1", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    vim.fn.setqflist({})
    tarminal.errors_to_quickfix()
    assert.equals(1, #vim.fn.getqflist())

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    tarminal.jump_to_error()
    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    vim.fn.delete(file)
    vim.fn.delete(script)
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

  it("does not carry an entered directory across the current run boundary", function()
    local root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. "/stale", "p")
    local file = root .. "/a.c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    vim.fn.writefile({ "wrong", "file" }, root .. "/stale/a.c")
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({
      "cd " .. vim.fn.shellescape(root),
      ("printf '%%s\\n' \"ninja: Entering directory '%s'\" boundary 'a.c:2:1: error: boom'"):format(root .. "/stale"),
      "sleep 10",
    }, script)
    tarminal.setup({ shell = "sh " .. script })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()

    local boundary, target
    local seen = vim.wait(4000, function()
      for i, line in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
        boundary = line == "boundary" and i or boundary
        target = line:find("a.c:2:1: error", 1, true) and i or target
      end
      return boundary ~= nil and target ~= nil
    end, 50)
    assert.is_true(seen)
    vim.b[term_buf].run_start_row = boundary

    vim.api.nvim_win_set_cursor(term_win, { boundary, 0 })
    tarminal.next_error()
    assert.equals(target, vim.api.nvim_win_get_cursor(term_win)[1])
    tarminal.jump_to_error()

    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    vim.fn.delete(root, "rf")
    vim.fn.delete(script)
  end)

  it("navigates and jumps to a file under the directory make entered", function()
    local root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. "/sub", "p")
    local file = root .. "/sub/a.c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({
      ("printf '%%s\\n' \"make[1]: Entering directory '%s'\" 'a.c:2:1: error: boom'"):format(root .. "/sub"),
      "sleep 10",
    }, script)
    tarminal.setup({ shell = "sh " .. script, quickfix = { open = false, close_terminal = false } })
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local term_win = vim.api.nvim_get_current_win()

    local seen = vim.wait(4000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false), "\n")
      return text:find("a.c:2:1: error", 1, true) ~= nil
    end, 50)
    assert.is_true(seen)

    tarminal.errors_to_quickfix()
    local qf = vim.fn.getqflist()
    vim.api.nvim_win_set_cursor(term_win, { 1, 0 })
    tarminal.next_error()
    assert.is_truthy(vim.api.nvim_get_current_line():find("a.c:2:1", 1, true))
    tarminal.jump_to_error()

    assert.equals(1, #qf)
    assert.equals(file, vim.api.nvim_buf_get_name(qf[1].bufnr))
    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    vim.fn.delete(root, "rf")
    vim.fn.delete(script)
  end)
end)
