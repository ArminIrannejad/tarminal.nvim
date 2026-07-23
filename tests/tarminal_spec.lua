describe("tarminal", function()
  local tarminal

  -- Search `fn`'s upvalues for `wanted`, descending into function-valued
  -- upvalues (locals extracted into helpers, like execute_in_shell, put
  -- what they capture one level deeper).
  local function find_upvalue(fn, wanted, seen)
    if seen[fn] then
      return nil
    end
    seen[fn] = true
    local fns = {}
    for i = 1, 40 do
      local name, value = debug.getupvalue(fn, i)
      if not name then
        break
      end
      if name == wanted then
        return value
      end
      if type(value) == "function" then
        fns[#fns + 1] = value
      end
    end
    for _, f in ipairs(fns) do
      local value = find_upvalue(f, wanted, seen)
      if value ~= nil then
        return value
      end
    end
  end

  local function get_upvalue(fn, wanted)
    local value = find_upvalue(fn, wanted, {})
    if value == nil then
      error("missing upvalue: " .. wanted)
    end
    return value
  end

  -- Wait until run `id`'s banner is printed and the shell has taken the
  -- foreground back: only then will a follow-up run() not be refused by
  -- the busy guard (on slow CI the previous command is still running
  -- when two runs are issued back-to-back).
  local function wait_run_finished(term_buf, id)
    local token = ("RUN[%d]"):format(id)
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
    tarminal.setup({ time_runs = false, runners = { c = "clang -Wpedantic -Wall" } })
    local build = get_upvalue(tarminal.run, "build_runner_command")
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
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local ctx = { file = "/tmp/example.py", stem = "example", dir = "/tmp", ft = "python" }
    assert.equals("python '/tmp/example.py'", build(ctx))
  end)

  it("times runs only when a time binary is installed", function()
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local py = { file = "/tmp/example.py", stem = "example", dir = "/tmp", ft = "python" }
    local c = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }

    if vim.fn.executable("time") == 1 then
      assert.equals("time python '/tmp/example.py'", build(py))
      -- for a compile chain, only the produced binary is timed
      assert.equals("cc '/tmp/example.c' -o 'example' && time ./'example'", build(c))
    else
      -- no binary: the prefix is skipped so any POSIX shell can run this
      assert.equals("python '/tmp/example.py'", build(py))
      assert.equals("cc '/tmp/example.c' -o 'example' && ./'example'", build(c))
    end
  end)

  it("does not overwrite an extensionless source file when compiling", function()
    tarminal.setup({ time_runs = false })
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local command = build({ file = "/tmp/prog", stem = "prog", dir = "/tmp", ft = "c" })
    assert.equals("cc '/tmp/prog' -o 'prog.out' && ./'prog.out'", command)
  end)

  it("builds and runs the binary when a table runner sets run_binary", function()
    tarminal.setup({
      time_runs = false,
      runners = { zig = { cmd = "zig build-exe", run_binary = true } },
    })
    local build = get_upvalue(tarminal.run, "build_runner_command")
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
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local ctx = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }
    assert.equals("cc '/tmp/example.c'", build(ctx))
  end)

  it("infers running the binary by name for a table runner without a run_binary flag", function()
    tarminal.setup({ time_runs = false, runners = { c = { cmd = "clang -Wall" } } })
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local ctx = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }
    assert.equals("clang -Wall '/tmp/example.c' -o 'example' && ./'example'", build(ctx))
  end)

  it("appends a runner's args after the file", function()
    tarminal.setup({ time_runs = false })
    local build = get_upvalue(tarminal.run, "build_runner_command")
    -- the bundled odin runner: `odin run <file> -file`
    local ctx = { file = "/tmp/example.odin", stem = "example", dir = "/tmp", ft = "odin" }
    assert.equals("odin run '/tmp/example.odin' -file", build(ctx))
  end)

  it("places args after the source in a compiling runner", function()
    tarminal.setup({
      time_runs = false,
      runners = { c = { cmd = "cc", args = "-lm", run_binary = true } },
    })
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local ctx = { file = "/tmp/example.c", stem = "example", dir = "/tmp", ft = "c" }
    assert.equals("cc '/tmp/example.c' -lm -o 'example' && ./'example'", build(ctx))
  end)

  it("recognizes compiler paths and versioned compiler names", function()
    local build = get_upvalue(tarminal.run, "build_runner_command")
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

  it("cuts a blockwise selection at screen columns across tab widths", function()
    vim.bo.tabstop = 8
    -- A and B both sit at screen column 9, but at different byte columns
    -- (2 vs 9); a byte-column block would pull "2345678B" from the second row
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "\tA", "12345678B" })
    vim.fn.setpos("'<", { 0, 1, 2, 0 }) -- A, byte col 2, screen col 9
    vim.fn.setpos("'>", { 0, 2, 9, 0 }) -- B, byte col 9, screen col 9
    local get_selection = get_upvalue(tarminal.send_selection, "get_visual_selection")
    assert.equals("A\nB", get_selection("\22"))
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

  it("extracts the cwd path from macOS lsof -Fn output", function()
    local parse_lsof_cwd = get_upvalue(tarminal.jump_to_error, "parse_lsof_cwd")
    -- lsof -a -p <pid> -d cwd -Fn emits the pid, the fd, then the n<path> line
    assert.equals("/Users/armin/project", parse_lsof_cwd("p12345\nfcwd\nn/Users/armin/project\n"))
    -- a path containing spaces must survive intact
    assert.equals("/Users/a b/proj", parse_lsof_cwd("p1\nfcwd\nn/Users/a b/proj\n"))
    -- no n-line (e.g. permission denied) -> nil, so term_cwd falls back
    assert.is_nil(parse_lsof_cwd("p12345\n"))
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

  it("parses error locations whose paths contain parentheses", function()
    local dir = vim.fn.tempname()
    local file = dir .. "/report(audit).c"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "int main() {}" }, file)

    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    local parsed_file, line, col = parse(file .. ":1:2: error", vim.api.nvim_get_current_buf())
    vim.fn.delete(dir, "rf")

    assert.equals(file, parsed_file)
    assert.equals(1, line)
    assert.equals(2, col)
  end)

  it("unwraps a path the message encloses in parentheses (V8 stack trace)", function()
    local file = vim.fn.tempname() .. ".js"
    vim.fn.writefile({ "throw new Error()" }, file)

    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    local output = "    at Object.<anonymous> (" .. file .. ":1:7)"
    local parsed_file, line, col, span_start = parse(output, vim.api.nvim_get_current_buf())
    vim.fn.delete(file)

    assert.equals(file, parsed_file)
    assert.equals(1, line)
    assert.equals(7, col)
    -- the highlight span starts at the path, past the wrapping "("
    assert.equals(output:find(file, 1, true), span_start)
  end)

  it("unwraps a path glued to a prefix by a bracket (Java stack frame)", function()
    local dir = vim.fn.tempname()
    local file = dir .. "/Main.java"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "class Main {}" }, file)

    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
    -- the source name is glued to the frame's method with no space before "("
    local output = "\tat pkg.Main.run(" .. file .. ":123)"
    local parsed_file, line, col, span_start = parse(output, vim.api.nvim_get_current_buf())
    vim.fn.delete(dir, "rf")

    assert.equals(file, parsed_file)
    assert.equals(123, line)
    assert.is_nil(col)
    -- the highlight span starts at the path, past the glued "run("
    assert.equals(output:find(file, 1, true), span_start)
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

  it("classifies severity from the error pattern's type capture", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main() {}" }, file)
    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
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

  it("matches a user-added pattern and trusts it with resolve = false", function()
    tarminal.setup({
      error_patterns = {
        { pattern = "at (%S+) line (%d+)", file = 1, lnum = 2, resolve = false },
      },
    })
    local parse = get_upvalue(tarminal.jump_to_error, "parse_error_line")
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
    local logical_line_at = get_upvalue(tarminal.jump_to_error, "logical_line_at")
    local logical, first, last = logical_line_at({ "éé", "tail" }, 2, 4)
    assert.equals("tail", logical)
    assert.equals(2, first)
    assert.equals(2, last)
  end)

  it("recognizes REPL entries that disable bracketed paste", function()
    local send = get_upvalue(tarminal.send_cell, "send_to_repl")
    local spec = get_upvalue(send, "repl_spec")
    local cmd, bracketed = spec("python")
    assert.equals("ipython", cmd)
    assert.is_true(bracketed)
    cmd, bracketed = spec("ocaml")
    assert.equals("ocaml", cmd)
    assert.is_false(bracketed)
    -- ghci's line editor mishandles bracketed paste, so the default sends raw
    cmd, bracketed = spec("haskell")
    assert.equals("ghci", cmd)
    assert.is_false(bracketed)
  end)

  it("wraps REPL sends in bracketed paste by default", function()
    -- a "REPL" that copies its stdin to a file, so the exact bytes the REPL
    -- receives can be inspected
    local out = vim.fn.tempname()
    tarminal.setup({
      follow_repl = "none",
      repls = { lua = "cat > " .. vim.fn.shellescape(out) },
    })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print(1)", "print(2)" })
    vim.bo.filetype = "lua"

    tarminal.send_cell()

    local received = vim.wait(8000, function()
      return vim.fn.filereadable(out) == 1 and table.concat(vim.fn.readfile(out), "\n"):find("\27[201~", 1, true) ~= nil
    end, 50)
    local content = table.concat(vim.fn.readfile(out), "\n")
    vim.fn.delete(out)
    assert.is_true(received)
    assert.is_truthy(content:find("\27[200~print(1)\nprint(2)\n\27[201~", 1, true))
  end)

  it("sends raw text to a REPL with bracketed paste disabled", function()
    local out = vim.fn.tempname()
    tarminal.setup({
      follow_repl = "none",
      repls = { lua = { cmd = "cat > " .. vim.fn.shellescape(out), bracketed_paste = false } },
    })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print(1)", "print(2)" })
    vim.bo.filetype = "lua"

    tarminal.send_cell()

    local received = vim.wait(8000, function()
      return vim.fn.filereadable(out) == 1 and table.concat(vim.fn.readfile(out), "\n"):find("print(2)", 1, true) ~= nil
    end, 50)
    local content = table.concat(vim.fn.readfile(out), "\n")
    vim.fn.delete(out)
    assert.is_true(received)
    -- no paste escape sequences reach a REPL that cannot parse them
    assert.is_falsy(content:find("\27", 1, true))
    assert.is_truthy(content:find("print(1)\nprint(2)", 1, true))
  end)

  it("wraps multi-line sends in the REPL's block markers", function()
    local out = vim.fn.tempname()
    tarminal.setup({
      follow_repl = "none",
      repls = {
        lua = {
          cmd = "cat > " .. vim.fn.shellescape(out),
          bracketed_paste = false,
          block_open = ":{",
          block_close = ":}",
        },
      },
    })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print(1)", "print(2)" })
    vim.bo.filetype = "lua"

    tarminal.send_cell()

    local received = vim.wait(8000, function()
      return vim.fn.filereadable(out) == 1 and table.concat(vim.fn.readfile(out), "\n"):find(":}", 1, true) ~= nil
    end, 50)
    local content = table.concat(vim.fn.readfile(out), "\n")
    vim.fn.delete(out)
    assert.is_true(received)
    -- block markers wrap the selection, no paste escapes
    assert.is_falsy(content:find("\27", 1, true))
    assert.is_truthy(content:find(":{\nprint(1)\nprint(2)\n:}", 1, true))
  end)

  it("leaves single-line sends unwrapped when block markers are set", function()
    local out = vim.fn.tempname()
    tarminal.setup({
      follow_repl = "none",
      repls = {
        lua = {
          cmd = "cat > " .. vim.fn.shellescape(out),
          bracketed_paste = false,
          block_open = ":{",
          block_close = ":}",
        },
      },
    })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print(1)" })
    vim.bo.filetype = "lua"

    tarminal.send_cell()

    local received = vim.wait(8000, function()
      return vim.fn.filereadable(out) == 1 and table.concat(vim.fn.readfile(out), "\n"):find("print(1)", 1, true) ~= nil
    end, 50)
    local content = table.concat(vim.fn.readfile(out), "\n")
    vim.fn.delete(out)
    assert.is_true(received)
    assert.is_falsy(content:find(":{", 1, true))
    assert.equals("print(1)", content)
  end)

  it("exposes block markers through repl_spec", function()
    local send = get_upvalue(tarminal.send_cell, "send_to_repl")
    local spec = get_upvalue(send, "repl_spec")
    local cmd, _, block_open, block_close = spec("haskell")
    assert.equals("ghci", cmd)
    assert.equals(":{", block_open)
    assert.equals(":}", block_close)
  end)

  local function toggle_and_get_row()
    tarminal.toggle()
    local term_win = vim.api.nvim_get_current_win()
    assert.equals("tarminal", vim.bo[vim.api.nvim_win_get_buf(term_win)].filetype)
    local row = vim.fn.win_screenpos(term_win)[1]
    tarminal.toggle()
    return row
  end

  it("split position follows 'splitbelow' by default", function()
    local saved = vim.o.splitbelow

    vim.o.splitbelow = true
    local below_row = toggle_and_get_row()
    vim.o.splitbelow = false
    local above_row = toggle_and_get_row()

    vim.o.splitbelow = saved
    assert.is_true(below_row > above_row)
  end)

  it("split_position overrides 'splitbelow'", function()
    local saved = vim.o.splitbelow
    vim.o.splitbelow = true

    tarminal.setup({ split_position = "top" })
    local top_row = toggle_and_get_row()
    tarminal.setup({ split_position = "bottom" })
    local bottom_row = toggle_and_get_row()

    vim.o.splitbelow = saved
    assert.is_true(top_row < bottom_row)
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

  it("cleans up and reports when the shell cannot start", function()
    tarminal.setup({ shell = "/definitely/missing-shell" })
    local notes = {}
    local orig = vim.notify
    vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
      notes[#notes + 1] = { msg = msg, level = level }
    end

    local before = #vim.api.nvim_list_wins()
    local ok = pcall(tarminal.toggle)
    -- retry to prove empty splits do not accumulate
    pcall(tarminal.toggle)
    vim.notify = orig

    assert.is_true(ok)
    assert.equals(before, #vim.api.nvim_list_wins())
    assert.is_nil(get_upvalue(tarminal.toggle, "find_live_terminal")("is_shell", true))
    assert.is_true(#notes >= 1)
    assert.equals(vim.log.levels.ERROR, notes[#notes].level)
  end)

  it("toggle hides the terminal even when it is the last window", function()
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    vim.cmd("wincmd o") -- the terminal becomes the only window
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))

    tarminal.toggle()
    assert.is_not.equals(term_buf, vim.api.nvim_get_current_buf())
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))

    -- the terminal survived and can be shown again
    tarminal.toggle()
    assert.equals(term_buf, vim.api.nvim_get_current_buf())
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
    -- the run goes through against the on-disk version, buffer untouched
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
    -- written here, so there is nothing to fail on
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "print('edited')" })
    vim.bo.readonly = true
    local before = tarminal._run_id

    tarminal.run()

    vim.bo.readonly = false
    vim.fn.delete(file)
    assert.equals(before + 1, tarminal._run_id)
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

  it("sends run commands with a history-suppressing leading space", function()
    -- a "shell" that copies its stdin to a file, so the exact bytes tarminal
    -- types at the prompt can be inspected
    local out = vim.fn.tempname()
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ "exec cat > " .. out }, script)
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

  -- a "shell" that copies its stdin to `out`, so the exact command exec
  -- sends can be inspected; returns the path of the capture file
  local function stdin_capture_shell()
    local out = vim.fn.tempname()
    local script = vim.fn.tempname() .. ".sh"
    vim.fn.writefile({ "exec cat > " .. out }, script)
    return out, script
  end

  local function wait_capture(out, needle)
    return vim.wait(8000, function()
      return vim.fn.filereadable(out) == 1 and table.concat(vim.fn.readfile(out), "\n"):find(needle, 1, true) ~= nil
    end, 50)
  end

  it("does not pad bannered runs with blank terminal lines", function()
    local out, script = stdin_capture_shell()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ park_on_error = false, follow_run = "none", shell = "sh " .. script, runners = { lua = "true" } })

    tarminal.run()

    assert.is_true(wait_capture(out, "RUN["))
    local command = table.concat(vim.fn.readfile(out), "\n")
    vim.fn.delete(out)
    vim.fn.delete(script)
    vim.fn.delete(file)
    assert.is_nil(command:find("\\n\\n", 1, true))
    assert.is_nil(command:find("\\033[H", 1, true))
  end)

  it("exec expands % against the current file", function()
    local out, script = stdin_capture_shell()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    tarminal.setup({ banner = false, park_on_error = false, follow_run = "none", shell = "sh " .. script })

    -- the shape the :Tarminal command dispatcher passes (raw .args, plus the
    -- pre-tokenized .fargs)
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

    -- .fargs would collapse the quotes to `echo a  b` (two args, lost
    -- spacing); .args keeps the literal command
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

    -- a bare exec still prompts, pre-filled with the expanded command;
    -- accepting it must resend verbatim, not re-expand % against the
    -- terminal buffer (which would send `echo ran <terminal name>`)
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
    local term_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "tarminal" then
        term_buf = buf
      end
    end
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
    local function banner_row(token)
      for row, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
        if l:match("^=====") and l:find(token, 1, true) then
          return row
        end
      end
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
    assert.is_not_nil(banner_row(first))

    tarminal.run()
    local second = ("RUN[%d]"):format(tarminal._run_id)
    assert.is_true(vim.wait(4000, function()
      return banner_row(second) ~= nil
    end, 50))
    -- The first run remains in the buffer while the window is scrolled to
    -- the second banner; no terminal output is needed to pad the viewport.
    assert.is_not_nil(banner_row(first))
    local find_win_for_buf = get_upvalue(tarminal.run, "find_win_for_buf")
    local term_win = find_win_for_buf(term_buf)
    assert.is_true(vim.wait(4000, function()
      return vim.api.nvim_win_call(term_win, function()
        return vim.fn.winsaveview().topline == banner_row(second)
      end)
    end, 50))
    vim.fn.delete(file)
  end)

  -- Headless nvim never reaches terminal-insert ("t") mode, so this exercises
  -- the immediate-pin path rather than the deferred flush; it guards that
  -- insert-follow still lands the banner at the top of the window.
  it("aligns the banner to the window top in insert-follow", function()
    local file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "print('ok')" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.bo.filetype = "lua"
    tarminal.setup({ park_on_error = false, follow_run = "insert", runners = { lua = "true" } })

    tarminal.run()
    local token = ("RUN[%d]"):format(tarminal._run_id)

    local term_buf
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "tarminal" then
        term_buf = buf
      end
    end
    assert.is_not_nil(term_buf)
    assert.is_true(wait_run_finished(term_buf, tarminal._run_id))

    local function banner_row()
      for row, l in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)) do
        if l:match("^=====") and l:find(token, 1, true) then
          return row
        end
      end
    end

    local find_win_for_buf = get_upvalue(tarminal.run, "find_win_for_buf")
    local term_win = find_win_for_buf(term_buf)
    assert.is_true(vim.wait(4000, function()
      return vim.api.nvim_win_call(term_win, function()
        return vim.fn.winsaveview().topline == banner_row()
      end)
    end, 50))
    vim.cmd("stopinsert")
    vim.fn.delete(file)
  end)

  it("collects only locations at or above error_threshold into quickfix", function()
    vim.fn.setqflist({})
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int a;", "int b;" }, file)
    -- a script (no prompt or command echo) prints a warning then an error
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
    -- the warning is below threshold; only the error is collected
    assert.equals(1, #qf)
    assert.equals(2, qf[1].lnum)
    assert.equals("E", qf[1].type)
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
    local file = vim.fn.tempname() .. ".c"
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

    -- the terminal is no longer displayed; the quickfix window took over
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      assert.is_not.equals(term_buf, vim.api.nvim_win_get_buf(win))
    end
    vim.fn.delete(file)
    vim.fn.delete(script)
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
    local file = vim.fn.tempname() .. ".txt"
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

  it("does not send REPL input to the shell when the REPL fails to start", function()
    -- the guard reads /proc children; skip where the kernel does not expose it
    if vim.fn.filereadable("/proc/self/task/" .. vim.fn.getpid() .. "/children") == 0 then
      return
    end
    -- a real shell so `false` runs and exits, leaving the bare prompt that the
    -- cell must not be sent to
    tarminal.setup({ follow_repl = "none", shell = "/bin/sh", repls = { lua = "false" } })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print(1)" })
    vim.bo.filetype = "lua"

    local errored = false
    local orig = vim.notify
    vim.notify = function(_, level) ---@diagnostic disable-line: duplicate-set-field
      if level == vim.log.levels.ERROR then
        errored = true
      end
    end
    local ok = pcall(tarminal.send_cell)
    vim.notify = orig

    assert.is_true(ok)
    assert.is_true(errored)
    -- the failed REPL buffer is torn down, not left to receive shell input
    local repl
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].repl_ft ~= nil then
        repl = buf
      end
    end
    assert.is_nil(repl)
  end)
end)
