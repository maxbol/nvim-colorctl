# nvim-colorctl

CLI tool that sets the colorscheme and related options for all running Neovim instances.

## Installation

Through Nix:

```sh
nix build .#default
cp result/bin/nvim-colorctl ~/bin/
```

By hand (using zig 0.13.0):

```sh
zig build
cp zig-out/bin/nvim-colorctl ~/bin/
```

## Example usage

```sh
# Most basic usage, simply set the colorscheme of all running editors
nvim-colorctl -s tokyo-night

# List all available colorschemes
nvim-colorctl -l

# Set the colorscheme and the background color
nvim-colorctl -s tokyo-night -b dark

# Set specific highlight group guifg/guibg
nvim-colorctl --hi-bg CursorLine,#ff0000 --hi-fg CursorLineNr,#ff0000

# Emit configuration files to persist changes in scripting language of choice
nvim-colorctl -s tokyo-night --emit-lua ~/.config/nvim/lua/colorscheme.lua --emit-vim ~/.config/nvim/colorscheme.vim
```
