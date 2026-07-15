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

  before_each(function()
    tarminal = require("tarminal")
    tarminal.setup()
    vim.cmd("enew!")
  end)

  after_each(function()
    tarminal.setup()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
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
    assert.equals("ipython", tarminal.config.repls.python)
  end)

  local function has_normal_map(desc)
    for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
      if map.desc == desc then
        return true
      end
    end
    return false
  end

  it("setup creates no keymaps by default", function()
    tarminal.setup()
    assert.is_false(has_normal_map("Toggle shell terminal"))
  end)

  it("setup maps only the configured keys", function()
    tarminal.setup({ keymaps = { toggle = "<leader>ts" } })
    assert.is_true(has_normal_map("Toggle shell terminal"))
    assert.is_false(has_normal_map("Run current file in terminal"))
  end)

  it("setup resets previous options and mappings", function()
    tarminal.setup({ split_height = 20, keymaps = { toggle = "<leader>ts" } })
    tarminal.setup()
    assert.equals(12, tarminal.config.split_height)
    assert.is_false(has_normal_map("Toggle shell terminal"))
  end)

  it("uses the configured C compiler", function()
    tarminal.setup({ runners = { c = "clang" } })
    local build = get_upvalue(tarminal.run, "build_runner_command")
    local command = build({
      file = "/tmp/example.c",
      stem = "example",
      dir = "/tmp",
      ft = "c",
    })
    assert.is_truthy(command:match("^clang "))
    assert.is_falsy(command:match("^cc "))
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
    tarminal.setup({ keymaps = { term_normal = "<Esc><Esc>", jump_to_error = "<CR>" } })
    for _, map in ipairs(vim.api.nvim_get_keymap("t")) do
      assert.is_not.equals("Terminal: exit to normal mode", map.desc)
    end
    vim.cmd("terminal")
    local buf = vim.api.nvim_get_current_buf()
    assert.is_not.equals("tarminal", vim.bo[buf].filetype)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      assert.is_not.equals("Jump to file location under cursor", map.desc)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
