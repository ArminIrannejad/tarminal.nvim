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
    tarminal.setup()
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

  it("opens a full height split on the side for left and right", function()
    tarminal.setup({ split_position = "right", split_width = 30 })
    tarminal.toggle()
    local win = vim.api.nvim_get_current_win()
    assert.equals(30, vim.api.nvim_win_get_width(win))
    assert.is_true(vim.fn.win_screenpos(win)[2] > 1)
    assert.is_true(vim.wo[win].winfixwidth)
    tarminal.toggle()

    tarminal.setup({ split_position = "left", split_width = 30 })
    tarminal.toggle()
    assert.equals(1, vim.fn.win_screenpos(vim.api.nvim_get_current_win())[2])
  end)

  it("opens and toggles a centered float with layout float", function()
    tarminal.setup({ layout = "float", float = { width = 40, height = 0.5, border = "single" } })
    local before = #vim.api.nvim_list_wins()
    tarminal.toggle()
    local win = vim.api.nvim_get_current_win()
    local cfg = vim.api.nvim_win_get_config(win)
    assert.equals("editor", cfg.relative)
    assert.is_truthy(vim.inspect(cfg.title):find(" shell ", 1, true))
    assert.equals(40, cfg.width)
    assert.equals(math.floor((vim.o.lines - vim.o.cmdheight) * 0.5), cfg.height)
    assert.is_true(vim.b[vim.api.nvim_win_get_buf(win)].is_shell)

    tarminal.toggle()
    assert.equals(before, #vim.api.nvim_list_wins())
    tarminal.toggle()
    assert.equals("editor", vim.api.nvim_win_get_config(0).relative)

    tarminal.config.float.width = 50
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.equals(50, vim.api.nvim_win_get_config(0).width)
  end)

  it("lets a layout function open the window", function()
    local got
    tarminal.setup({
      layout = function(buf)
        got = buf
        vim.cmd("tabnew")
        return vim.api.nvim_get_current_win()
      end,
    })
    local first_tab = vim.api.nvim_get_current_tabpage()
    tarminal.toggle()
    local buf = vim.api.nvim_get_current_buf()
    assert.equals(got, buf)
    assert.is_true(vim.b[buf].is_shell)
    assert.is_not.equals(first_tab, vim.api.nvim_get_current_tabpage())
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

  it("hides the terminal in every tab and shows it again in this one", function()
    tarminal.toggle()
    local term_buf = vim.api.nvim_get_current_buf()
    local first_tab = vim.api.nvim_get_current_tabpage()
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(first_tab))

    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    tarminal.toggle()
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(first_tab))
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(second_tab))

    tarminal.toggle()
    assert.equals(term_buf, vim.api.nvim_get_current_buf())
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(second_tab))
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(first_tab))
  end)

  it("toggles a terminal living in its own tab without piling up tabs", function()
    tarminal.setup({
      layout = function()
        vim.cmd("tabnew")
        return vim.api.nvim_get_current_win()
      end,
    })
    tarminal.toggle()
    assert.equals(2, #vim.api.nvim_list_tabpages())
    vim.cmd("tabprevious")

    tarminal.toggle()
    assert.equals(1, #vim.api.nvim_list_tabpages())
    tarminal.toggle()
    assert.equals(2, #vim.api.nvim_list_tabpages())
    assert.is_true(vim.b.is_shell)
  end)

  it("brings hidden terminals back where and as big as they were", function()
    local out = vim.fn.tempname()
    tarminal.setup({ split_position = "right", split_width = 30, repls = { lua = "cat > " .. vim.fn.shellescape(out) } })
    vim.bo.filetype = "lua"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = 1" })
    local code_win = vim.api.nvim_get_current_win()
    tarminal.send_cell()
    local repl_buf = vim.api.nvim_win_get_buf(term.find_win_for_buf(term.find_live_terminal("repl_ft", "lua")))
    tarminal.config.split_position = "bottom"
    vim.api.nvim_set_current_win(code_win)
    tarminal.exec("true", true)
    local shell_win = term.find_win_for_buf(term.find_live_terminal("is_shell", true))
    vim.api.nvim_win_set_height(shell_win, 7)
    local repl_win = term.find_win_for_buf(repl_buf)
    vim.api.nvim_win_set_width(repl_win, 44)

    tarminal.toggle()
    assert.is_nil(term.find_win_for_buf(repl_buf))
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))

    tarminal.config.split_position = "top"
    tarminal.toggle()
    shell_win = term.find_win_for_buf(term.find_live_terminal("is_shell", true))
    repl_win = term.find_win_for_buf(repl_buf)
    assert.equals(7, vim.api.nvim_win_get_height(shell_win))
    assert.equals(44, vim.api.nvim_win_get_width(repl_win))
    assert.is_true(vim.fn.win_screenpos(repl_win)[2] > 1)
    assert.is_true(vim.fn.win_screenpos(shell_win)[1] > 1)
    vim.fn.delete(out)
  end)

  -- a capture shell named bash so the OSC 7 snippet is selected
  local function capture_bash()
    return helpers.stdin_capture_shell(false, "bash")
  end

  local function toggle_and_capture(probe, out, shell)
    local platform = require("tarminal.platform")
    local saved = platform.has_cwd_probe
    platform.has_cwd_probe = function()
      return probe
    end
    tarminal.setup({ shell = shell })
    tarminal.toggle()
    local buf = vim.api.nvim_get_current_buf()
    term.term_send_command(buf, "MARKER")
    local seen = helpers.wait_capture(out, "MARKER")
    platform.has_cwd_probe = saved
    assert.is_true(seen)
    return table.concat(vim.fn.readfile(out), "\n")
  end

  it("types the OSC 7 snippet when no cwd probe answers", function()
    local out, shell = capture_bash()
    local typed = toggle_and_capture(false, out, shell)
    vim.fn.delete(out)
    vim.fn.delete(vim.fn.fnamemodify(shell, ":h"), "rf")

    assert.is_truthy(typed:find("__tarminal_osc7", 1, true))
    assert.is_truthy(typed:find("\\033[3J", 1, true))
  end)

  it("skips the OSC 7 snippet when the cwd probe answers", function()
    local out, shell = capture_bash()
    local typed = toggle_and_capture(true, out, shell)
    vim.fn.delete(out)
    vim.fn.delete(vim.fn.fnamemodify(shell, ":h"), "rf")

    assert.is_nil(typed:find("__tarminal_osc7", 1, true))
    assert.is_nil(typed:find("\\033[3J", 1, true))
  end)

  it("does not touch terminals it did not create", function()
    vim.cmd("terminal")
    local buf = vim.api.nvim_get_current_buf()
    assert.is_not.equals("tarminal", vim.bo[buf].filetype)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("keeps the term name with keep_term_name so user term autocmds still match", function()
    local hits = {}
    local group = vim.api.nvim_create_augroup("tarminal-test-term", { clear = true })
    for _, event in ipairs({ "BufEnter", "TermClose" }) do
      vim.api.nvim_create_autocmd(event, {
        group = group,
        pattern = "term://*",
        callback = function()
          hits[event] = true
        end,
      })
    end

    tarminal.setup({ keep_term_name = true })
    tarminal.toggle()
    local buf = vim.api.nvim_get_current_buf()
    assert.is_truthy(vim.startswith(vim.api.nvim_buf_get_name(buf), "term://"))
    vim.cmd("wincmd p")
    vim.cmd("wincmd p")
    vim.fn.jobstop(vim.b[buf].terminal_job_id)
    vim.wait(2000, function()
      return hits.TermClose
    end, 20)
    vim.api.nvim_del_augroup_by_id(group)

    assert.is_true(hits.BufEnter)
    assert.is_true(hits.TermClose)
  end)

  it("sets win_opts on a new terminal and leaves the rest alone", function()
    local group = vim.api.nvim_create_augroup("tarminal-test-winopts", { clear = true })
    vim.api.nvim_create_autocmd("TermOpen", {
      group = group,
      callback = function()
        vim.opt_local.number = true
        vim.opt_local.scrolloff = 5
      end,
    })

    tarminal.toggle()
    assert.is_false(vim.wo.number)
    assert.equals(0, vim.wo.scrolloff)
    tarminal.toggle()
    vim.api.nvim_buf_delete(term.find_live_terminal("is_shell", true), { force = true })

    tarminal.setup({ win_opts = { signcolumn = "yes" } })
    tarminal.toggle()
    vim.api.nvim_del_augroup_by_id(group)
    assert.is_true(vim.wo.number)
    assert.equals(5, vim.wo.scrolloff)
    assert.equals("yes", vim.wo.signcolumn)
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
