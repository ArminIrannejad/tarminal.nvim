local helpers = require("tests.helpers")

describe("tarminal repl", function()
  local tarminal = require("tarminal")
  local repl = require("tarminal.repl")

  helpers.hooks()

  it("extracts an exact single-line visual selection", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdefgh" })
    vim.fn.setpos("'<", { 0, 1, 3, 0 })
    vim.fn.setpos("'>", { 0, 1, 5, 0 })
    local get_selection = repl.get_visual_selection
    assert.equals("cde", get_selection("v"))
  end)

  it("keeps a trailing multibyte character in a charwise selection", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcé" })
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 4, 0 }) -- é occupies bytes 4-5
    local get_selection = repl.get_visual_selection
    assert.equals("abcé", get_selection("v"))
  end)

  it("keeps multibyte characters inside a blockwise selection", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "xéy", "abc" })
    vim.fn.setpos("'<", { 0, 1, 2, 0 })
    vim.fn.setpos("'>", { 0, 2, 2, 0 })
    local get_selection = repl.get_visual_selection
    assert.equals("é\nb", get_selection("\22"))
  end)

  it("drops the endpoint char in a charwise selection when selection=exclusive", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdefgh" })
    vim.fn.setpos("'<", { 0, 1, 3, 0 })
    vim.fn.setpos("'>", { 0, 1, 5, 0 })
    local get_selection = repl.get_visual_selection
    local prev = vim.o.selection
    vim.o.selection = "exclusive"
    local got = get_selection("v")
    vim.o.selection = prev -- restore before asserting so a failure can't leak
    assert.equals("cd", got)
  end)

  it("drops the endpoint column in a blockwise selection when selection=exclusive", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcd", "efgh" })
    vim.fn.setpos("'<", { 0, 1, 2, 0 })
    vim.fn.setpos("'>", { 0, 2, 4, 0 })
    local get_selection = repl.get_visual_selection
    local prev = vim.o.selection
    vim.o.selection = "exclusive"
    local got = get_selection("\22")
    vim.o.selection = prev
    assert.equals("bc\nfg", got) -- inclusive would keep the endpoint column: "bcd"/"fgh"
  end)

  it("cuts a blockwise selection at screen columns across tab widths", function()
    vim.bo.tabstop = 8
    -- A and B both sit at screen column 9 but at different byte columns
    -- a byte-column block would pull "2345678B" from the second row
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "\tA", "12345678B" })
    vim.fn.setpos("'<", { 0, 1, 2, 0 }) -- A, byte col 2, screen col 9
    vim.fn.setpos("'>", { 0, 2, 9, 0 }) -- B, byte col 9, screen col 9
    local get_selection = repl.get_visual_selection
    assert.equals("A\nB", get_selection("\22"))
  end)

  it("reads no selection from a buffer that has never been in visual mode", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdefgh" })
    vim.fn.setpos("'<", { 0, 0, 0, 0 })
    vim.fn.setpos("'>", { 0, 0, 0, 0 })
    assert.is_nil(repl.get_visual_selection("v"))
  end)

  it("warns instead of erroring when send_selection has no selection to send", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print(1)" })
    vim.bo.filetype = "lua"
    vim.fn.setpos("'<", { 0, 0, 0, 0 })
    vim.fn.setpos("'>", { 0, 0, 0, 0 })

    local warned
    local notify = vim.notify
    vim.notify = function(msg, level)
      warned = warned or (level == vim.log.levels.WARN and msg)
    end
    local ok, err = pcall(tarminal.send_selection)
    vim.notify = notify

    assert.is_true(ok, tostring(err))
    assert.equals("No visual selection to send", warned)
  end)

  it("extracts an explicit line range", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
    local get_range = repl.get_line_range
    assert.equals("two\nthree", get_range(2, 3))
  end)

  it("uses the cell after a marker when the cursor is on the marker", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "print(1)",
      "# COMMAND ----------",
      "print(2)",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local get_cell = repl.get_current_cell_text
    assert.equals("print(2)\n", get_cell())
  end)

  it("does not treat a marker substring as a cell boundary", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "print(1)",
      'print("# COMMAND ----------")',
      "print(2)",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local get_cell = repl.get_current_cell_text
    assert.equals('print(1)\nprint("# COMMAND ----------")\nprint(2)\n', get_cell())
  end)

  it("recognizes REPL entries that disable bracketed paste", function()
    local send = repl.send_to_repl
    local spec = repl.repl_spec
    local cmd, bracketed = spec("python")
    assert.equals("ipython", cmd)
    assert.is_true(bracketed)
    cmd, bracketed = spec("ocaml")
    assert.equals("ocaml", cmd)
    assert.is_false(bracketed)
    -- ghci's line editor mishandles bracketed paste so the default sends raw
    cmd, bracketed = spec("haskell")
    assert.equals("ghci", cmd)
    assert.is_false(bracketed)
  end)

  it("wraps REPL sends in bracketed paste by default", function()
    -- a "REPL" that copies its stdin to a file so the exact bytes it
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
    -- block markers wrap the selection with no paste escapes
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
    local send = repl.send_to_repl
    local spec = repl.repl_spec
    local cmd, _, block_open, block_close = spec("haskell")
    assert.equals("ghci", cmd)
    assert.equals(":{", block_open)
    assert.equals(":}", block_close)
  end)

  it("does not send REPL input to the shell when the REPL fails to start", function()
    -- the guard reads /proc children so skip where the kernel hides it
    if vim.fn.filereadable("/proc/self/task/" .. vim.fn.getpid() .. "/children") == 0 then
      return
    end
    -- a real shell so `false` runs and exits leaving the bare prompt that
    -- the cell must not be sent to
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
    -- the failed REPL buffer is torn down and not left to receive shell input
    local repl
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].repl_ft ~= nil then
        repl = buf
      end
    end
    assert.is_nil(repl)
  end)
end)
