{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs.lib) recursiveUpdate;
      # This file is laid out a bit backwards for readability's sake.
      # This is the final output, it's going to be a nice output of all the
      # packages, with the devshell and overlays merged into one output.
      # outs is how we get the final output, where all the packages are joined
      # and then a default overlay and devshell is created with all of the
      # requirements for each package.
      # merge :: [attrSet] -> attrSet
      rust-flakes =
        output-list: builtins.removeAttrs (builtins.foldl' mergeOutputs { } output-list) [ "all-deps" ];

      # Merges two of the rust-flakes into a single output. It's not suitable to
      # use directly yet. Use `merge` instead.
      mergeOutputs =
        left: right:
        let

          # Defaults from the left and right that we need
          # Overlays
          lo = left.overlays.default or (_: _: { });
          ro = right.overlays.default or (_: _: { });
          # Dependencies
          ld = left.all-deps or (_: [ ]);
          rd = right.all-deps or (_: [ ]);
          # Packages
          lp = left.packages or { };
          rp = right.packages or { };
          overlay-all = (final: prev: (lo final prev) // (ro final prev));
          all-deps = p: (ld p) ++ (rd p);
        in
        {
          inherit all-deps;
          packages = recursiveUpdate lp rp;
          overlays.default = overlay-all;
          devShells = forEachSupportedSystem overlay-all (
            { pkgs }:
            {
              default = pkgs.mkShell {
                # Join all the deps together
                packages = [
                  pkgs.rustToolchain-dev'
                ]
                ++ (all-deps pkgs);
              };
            }
          );
        };

      forEachSupportedSystem =
        overlay: f:
        inputs.nixpkgs.lib.genAttrs (import inputs.systems) (
          system:
          f {
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [
                inputs.rust-overlay.overlays.default
                overlay
              ];
            };
          }
        );
      rust-flake =
        {
          # The root of your rust crate
          root,
          repo-root ? root,
          # Use the workspace instead of the normal package.* info
          workspace ? false,
          # Extra files to include in the source
          extra_files ? [ ],
          # The `deps-*` variables should be functions that take a package set as
          # a variable.
          # Dependencies required only for the build (`nativeBuildInputs`)
          deps-build ? _: [ ],
          # Runtime dependencies (`buildInputs`)
          deps-run ? _: [ ],
          # Development dependencies (for the devShells)
          deps-dev ? _: [ ],
          # Will also create a default output.
          is-default ? true,
          # Specify an alternate toolchain file (useful for sub-crates)
          toolchain ? repo-root + /rust-toolchain.toml,
          toolchain-overrides ? { },
          dev-overrides ? {
            extensions = [
              "rust-src"
              "rust-analyzer"
            ];
          },
          ...
        }@rustArgs:
        let
          ## Be careful editing anything below here. ##
          # Stores a nix object from the Cargo.toml file
          cargoToml =
            let
              c = builtins.fromTOML (builtins.readFile (root + /Cargo.toml));
            in
            if workspace then c.workspace else c;
          pname = rustArgs.name_override or cargoToml.package.name;
          name = pname;

          # Easy way to get just the rust source stuff that we care about without
          # rebuilding when non-code stuff changes
          inherit (inputs.nixpkgs.lib.fileset)
            toSource
            intersection
            unions
            maybeMissing
            ;
          rustSrc = toSource {
            inherit root;
            fileset = (
              intersection root (
                unions (
                  [
                    (maybeMissing (root + /Cargo.toml))
                    (maybeMissing (root + /Cargo.lock))
                    (maybeMissing (root + /src))
                  ]
                  ++ (map maybeMissing extra_files)
                )
              )
            );
          };
          # Creates an overlay using rust-overlay and adds this package to it
          pkg-overlay = (
            final: prev: {
              # Add an override for the toolchain and platform
              # Uses the `foo'` notation because otherwise the recursion is nasty.
              # Split into two different toolchains, one with stuff for development,
              # and the other only containing the base toolchain.
              rustToolchain' = (prev.rust-bin.fromRustupToolchainFile toolchain).override toolchain-overrides;
              rustToolchain-dev' = final.rustToolchain'.override toolchain-overrides // dev-overrides;
              rustPlatform' = final.makeRustPlatform {
                cargo = final.rustToolchain';
                rustc = final.rustToolchain';
              };
              "${name}" = final.rustPlatform'.buildRustPackage (
                {
                  inherit pname;
                  version = cargoToml.package.version;
                  src = rustSrc;
                  cargoLock.lockFile = root + /Cargo.lock;

                  meta = (
                    {
                      homepage = cargoToml.package.repository or "https://example.com";
                      mainProgram = name;

                      inherit (cargoToml.package) description;
                    }
                    // {
                      description = (cargoToml.package.description or "default description");
                    }
                  );
                }
                // (
                  if (deps-build final) != [ ] then
                    {
                      nativeBuildInputs = deps-build final;
                    }
                  else
                    { }
                )
                // (
                  if (deps-run final) != [ ] then
                    {
                      buildInputs = deps-run final;
                    }
                  else
                    { }
                )
              );
            }
          );
          final-outputs = final-name: {
            # `nix run` works with the package now that it has mainProgram set
            packages = forEachSupportedSystem pkg-overlay (
              { pkgs }:
              {
                "${final-name}" = pkgs.${name};
              }
            );
            # Allow using this in other flakes as an overlay easily
            overlays = {
              default = pkg-overlay;
            };
            all-deps = p: (deps-build p) ++ (deps-run p) ++ (deps-dev p);
          };
        in
        final-outputs (if is-default then "default" else name);
    in
    {
      lib = {
        inherit rust-flake rust-flakes;
      };
    };
}
