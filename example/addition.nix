{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    rust-flake.url = "../";
  };
  outputs =
    inputs:
    let
      inherit (inputs.rust-flake.lib) rust-flake rust-flakes;
      forEachSupportedSystem =
        f:
        inputs.nixpkgs.lib.genAttrs (import inputs.systems) (
          system: f { pkgs = import inputs.nixpkgs { inherit system; }; }
        );
    in
    inputs.nixpkgs.lib.recursiveUpdate
      {
        packages = forEachSupportedSystem (
          { pkgs }:
          {
            hello = pkgs.hello;
          }
        );
      }
      (rust-flakes [
        (rust-flake {
          root = ./.;
        })
        (rust-flake {
          name_override = "complex-example";
          root = ./.;
          is-default = false;
          # With system specific packages
          deps-build = p: with p; ([ hello ] ++ (if stdenv.isLinux then [ fuse3 ] else [ darwin.icu ]));
          deps-run = p: with p; [ ponysay ];
          dev-overrides = {
            extensions = [
              "rust-analyzer"
              "clippy"
            ];
          };

        })
      ]);
}
