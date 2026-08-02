--- Config types and the active options table

---@alias tarminal.Follow
---| '"none"'   # stay in the code window
---| '"focus"'  # terminal window in normal mode
---| '"insert"' # terminal window in insert mode

---@alias tarminal.SplitPosition
---| '"auto"'   # follow 'splitbelow'
---| '"bottom"' # always bottom
---| '"top"'    # always top

---@class tarminal.Config
---@field split_height integer
---@field split_position tarminal.SplitPosition
---@field shell string
---@field follow_run tarminal.Follow
---@field follow_repl tarminal.Follow
---@field autosave boolean write the buffer before a run else use disk
---@field park_on_error boolean highlight errors and park on the first
---@field close_on_jump boolean close the terminal after jump_to_error lands
---@field cell_marker string line that delimits REPL cells
---@field time_runs boolean `time` the run when a time binary exists
---@field banner boolean print a RUN banner before each run
---@field clear_run boolean wipe the terminal + scrollback before each run (not scrollable)
---@field shell_integration boolean emit + track cwd via OSC 7 in the spawned shell
---@field runners table<string, string|tarminal.Runner> filetype -> run command
---@field compilers string[] program names built with `-o` then run
---@field repls table<string, string|tarminal.Repl> filetype -> REPL command
---@field error_patterns tarminal.ErrorPattern[] error formats tried in order
---@field error_threshold integer min severity to park/step/collect (0 note 1 warn 2 error)
---@field quickfix tarminal.Quickfix

---@class tarminal.Quickfix
---@field open boolean open quickfix after collecting
---@field close_terminal boolean close the terminal after collecting

---@class tarminal.ErrorPattern
---@field pattern string Lua pattern matched against a whole line
---@field file integer capture index of the file
---@field lnum integer|nil capture index of the line
---@field col integer|nil capture index of the column
---@field type integer|string|nil capture index of a severity word or a fixed severity
---@field resolve boolean|nil default true needs the file on disk while false trusts it

---@class tarminal.Runner
---@field cmd string run command
---@field run_binary boolean|nil true builds with `-o` then runs the binary
---@field args string|nil flags appended after the file

---@class tarminal.Repl
---@field cmd string REPL command
---@field bracketed_paste boolean|nil false to send raw (can't parse paste escapes)
---@field block_open string|nil marker opening a multi-line block (ghci `:{`)
---@field block_close string|nil marker closing it (ghci `:}`)

-- path chars with no whitespace colon brackets or quotes
-- spaces and parens go through the fallback parser
local PATH = "([^%s:%(%)%[%]<>'\"]+)"

local defaults = {
  split_height = 12,
  split_position = "auto",
  shell = vim.env.SHELL or "/bin/bash",
  follow_run = "none",
  follow_repl = "none",
  autosave = true,
  park_on_error = true,
  close_on_jump = false,
  cell_marker = "# COMMAND ----------",
  time_runs = false,
  banner = false,
  clear_run = true,
  shell_integration = true,
  runners = {
    python = "python",
    sh = "bash",
    lua = "lua",
    javascript = "node",
    go = "go run",
    haskell = "runghc",
    ocaml = "ocaml",
    c = "cc",
    rust = "rustc",
    odin = { cmd = "odin run", args = "-file" },
  },
  -- only `cmd <src> -o <out>` compilers
  -- others need a run_binary runner
  compilers = {
    "cc",
    "gcc",
    "clang",
    "g++",
    "clang++",
    "c++",
    "rustc",
    "ghc",
    "swiftc",
    "gdc",
    "ocamlopt",
    "ocamlc",
  },
  repls = {
    python = "ipython",
    lua = "lua -i",
    javascript = "node",
    ruby = "irb",
    julia = "julia",
    r = "R",
    haskell = { cmd = "ghci", bracketed_paste = false, block_open = ":{", block_close = ":}" },
    ocaml = { cmd = "ocaml", bracketed_paste = false },
  },
  -- tried in order
  -- add your own for tools these miss
  error_patterns = {
    { pattern = PATH .. ":(%d+):(%d+):%s*(%l+)", file = 1, lnum = 2, col = 3, type = 4 },
    { pattern = PATH .. ":(%d+):(%d+)", file = 1, lnum = 2, col = 3 },
    { pattern = PATH .. ":(%d+):", file = 1, lnum = 2 },
    { pattern = 'File "([^"]+)", line (%d+)', file = 1, lnum = 2 },
  },
  error_threshold = 0,
  quickfix = {
    open = true,
    close_terminal = true,
  },
}

local M = {}

---@type tarminal.Config
M.opts = vim.deepcopy(defaults)

---@param opts tarminal.Config|nil merged over the defaults
function M.setup(opts)
  opts = opts or {}
  local extra = opts.error_patterns
  if extra then
    opts = vim.tbl_extend("force", {}, opts) -- shallow copy; don't mutate caller
    opts.error_patterns = nil
  end
  M.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if extra then
    M.opts.error_patterns = vim.list_extend(vim.deepcopy(extra), M.opts.error_patterns)
  end
end

return M
