# tarminal.nvim

A Neovim plugin. Describe what it does here.

## Requirements

- Neovim >= 0.9

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ArminIrannejad/tarminal.nvim",
  opts = {
    -- your options here
  },
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
  "ArminIrannejad/tarminal.nvim",
  config = function()
    require("tarminal").setup()
  end,
})
```

## Configuration

Default options:

```lua
require("tarminal").setup({
  -- add defaults here as the plugin grows
})
```

## Usage

- `:Tarminal` — open tarminal

## Development

```sh
make test    # run tests (requires plenary.nvim, cloned automatically)
make lint    # check formatting with stylua
make fmt     # format lua sources with stylua
```

## License

[MIT](./LICENSE)
