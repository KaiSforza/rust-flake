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
      # Optional function or just `f`
      ofunc =
        f: x: y:
        if (builtins.isFunction f) then (f x y) else (f);

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
          lo = left.overlays.default or { };
          ro = right.overlays.default or { };
          # Dependencies
          ld = left.all-deps or [ ];
          rd = right.all-deps or [ ];
          # Packages
          lp = left.packages or { };
          rp = right.packages or { };
          overlay-all = (final: prev: (ofunc lo final prev) // (ofunc ro final prev));
          all-deps = f: p: (ofunc ld f p) ++ (ofunc rd f p);
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
                ++ (all-deps pkgs pkgs);
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
          extra-files ? [ ],
          # Extra files to _exclude_ in the source
          exclude-files ? [ ],
          # The `deps-*` variables should be functions that take a package set as
          # a variable.
          # Dependencies required only for the build (`nativeBuildInputs`)
          deps-build ? [ ],
          # Runtime dependencies (`buildInputs`)
          deps-run ? [ ],
          # Development dependencies (for the devShells)
          deps-dev ? [ ],
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
          pkg-overrides ? { },
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
          pname = rustArgs.name-override or cargoToml.package.name;
          name = pname;

          # Easy way to get just the rust source stuff that we care about without
          # rebuilding when non-code stuff changes
          inherit (inputs.nixpkgs.lib.fileset)
            toSource
            intersection
            unions
            difference
            maybeMissing
            ;
          rustSrc = toSource {
            inherit root;
            fileset = (
              intersection root (
                difference (unions (
                  [
                    (maybeMissing (root + /Cargo.toml))
                    (maybeMissing (root + /Cargo.lock))
                    (maybeMissing (root + /src))
                  ]
                  ++ (map maybeMissing extra-files)
                )) exclude-files
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
              rustToolchain' = (prev.rust-bin.fromRustupToolchainFile toolchain).override (
                ofunc toolchain-overrides final prev
              );
              rustToolchain-dev' = final.rustToolchain'.override (
                (ofunc toolchain-overrides final prev) // (ofunc dev-overrides final prev)
              );
              rustPlatform' = final.makeRustPlatform {
                cargo = final.rustToolchain';
                rustc = final.rustToolchain';
              };
              "${name}" = (
                final.rustPlatform'.buildRustPackage (
                  {
                    inherit pname;
                    version = cargoToml.package.version;
                    src = rustSrc;
                    cargoLock.lockFile = root + /Cargo.lock;

                    meta = (
                      {
                        homepage = cargoToml.package.repository or "https://example.com";
                        mainProgram = name;
                      }
                      // {
                        description = (cargoToml.package.description or "default description");
                      }
                    );
                  }
                  // (
                    if (ofunc deps-build final prev) != [ ] then
                      {
                        nativeBuildInputs = ofunc deps-build final prev;
                      }
                    else
                      { }
                  )
                  // (
                    if (ofunc deps-run final prev) != [ ] then
                      {
                        buildInputs = ofunc deps-run final prev;
                      }
                    else
                      { }
                  )
                  // (ofunc pkg-overrides final prev)
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
            all-deps = f: p: (ofunc deps-build f p) ++ (ofunc deps-run f p) ++ (ofunc deps-dev f p);
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
