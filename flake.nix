{
  description = "Utility to control Neovim colorscheme from the terminal";

  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = {zig2nix, ...}: let
    flake-utils = zig2nix.inputs.flake-utils;
  in (flake-utils.lib.eachDefaultSystem (system: let
    # Zig flake helper
    # Check the flake.nix in zig2nix project for more options:
    # <https://github.com/Cloudef/zig2nix/blob/master/flake.nix>
    env = zig2nix.outputs.zig-env.${system} {
      zig = zig2nix.packages.${system}.zig-0_13_0;
    };
  in {
    packages.default = env.package {
      pname = "nvim-colorctl";
      version = "0.0.0";
      src = ./.;

      meta = {
        description = "Utility to control Neovim colorscheme from the terminal";
        mainProgram = "nvim-colorctl";
      };
    };

    # nix run .#zon2json
    apps.zon2json = env.app [env.zon2json] "zon2json \"$@\"";

    # nix run .#zon2json-lock
    apps.zon2json-lock = env.app [env.zon2json-lock] "zon2json-lock \"$@\"";

    # nix run .#zon2nix
    apps.zon2nix = env.app [env.zon2nix] "zon2nix \"$@\"";

    # nix develop
    devShells.default = env.mkShell {};
  }));
}
