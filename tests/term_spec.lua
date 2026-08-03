local helpers = require("tests.helpers")

describe("tarminal term", function()
  local tarminal = require("tarminal")
  local term = require("tarminal.term")

  helpers.hooks()

  it("keeps a spaced shell path as one argv entry", function()
    assert.same({ "bash", "-l" }, term.shell_cmd("bash -l"))

    local dir = vim.fn.tempname() .. " with space"
    vim.fn.mkdir(dir, "p")
    local exe = dir .. "/fakesh"
    vim.fn.writefile({ "#!/bin/sh" }, exe)
    vim.fn.setfperm(exe, "rwxr-xr-x")
    assert.same({ exe }, term.shell_cmd(exe))
    assert.same({ exe, "-l" }, term.shell_cmd(exe .. " -l"))
    vim.fn.delete(dir, "rf")
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
    assert.is_nil(term.find_live_terminal("is_shell", true))
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
end)
