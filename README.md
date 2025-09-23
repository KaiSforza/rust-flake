# rust-flake

A simple way to enable nix package, overlay and devShell creation for Rust
projects!

The idea is to be a _very_ simple flake to get a devshell and builder for rust
projects that already use the `rust-toolchain.toml` file. The
[`rust-overlay`][ro] is great for this, but it doesn't output a nice `package`
or `devShells` output. To enable a nice devShell, it should only require
following the flake example below. A `rust-toolchain.toml` file is required, and
is common in many rust projects.

Below is a simple example. See the `example/` directory for a full directory of
this example. `example2` has a more complex example with merging into another
flake output attribute set.

Note, right now this only handles simple rust projects.

[ro]: https://github.com/oxalica/rust-overlay

## Example

```nix
# ./flake.nix
{
  inputs.rust-flake.url = "github:KaiSforza/rust-flake";
  outputs =
    inputs:
    let
      inherit (inputs.rust-flake.lib) rust-flake rust-flakes;
    in
    rust-flakes [
      (rust-flake {
        root = ./.;
      })
    ];
}
```

```toml
# ./rust-toolchain.toml
[toolchain]
channel = "stable"
```

This will create a few things:

- `packages.${system}.default` - the main package from the `Cargo.toml` file in
  `./.`.
  - `packages.${system}.${name}` - If the `is-default` argument is `false`, it
    will create a separate `name` package.
- `devShells.${system}.default` - A devshell containing all of the build and run
  dependencies specified. Defaults to including a working `rust-overlay`
  toolchain based on the `toml` file. This toolchain includes the `rust-src` and
  `rust-analyzer` by default, but can be extended.
- `overlays.${system}.default` - A collection of all the packages in this flake
  that you can use as an overlay in another flake.

## Options to `rust-flake` function

### `root`

The root directory of the rust crate, should usually be `./.`. This is the only
_required_ setting.

### `repo-root = root`

The root for files that are required in the root of the repository. Only needed
if you are using a large mono-repo with different toolchain files, or if the
toolchain file is in a separate directory.

### `extra_files = [ ]`

By default, `Cargo.toml`, `Cargo.lock` and `src/` are included. Use this if you
need other files or directories.

### `deps-build = pkgs: [ ]`

Extra packages to include. Should be a function that will take a `pkgs`
argument. Gets added to `nativeBuildInputs` and to the devshell.

### `deps-run = pkgs: [ ]`

Extra packages that are needed at runtime. Should be a function that will take a
`pkgs` argument. Gets added to `buildInputs` and to the devshell.

### `is-default = true`

Will use the package name `default` instead of the cargo projects name or
`name_override`.

### `toolchain = repo-root + /rust-toolchain.toml`

The toolchain file to use, useful for

### `toolchain-overrides = { }`

Overrides for the toolchain in general. Will affect both the builder toolchain
as well as the devshell toolchain.

### `dev-overrides = {extensions = ["rust-src" "rust-analyzer"];}`

Overrides for just the devshell, having these in the builder causes the
toolchain to become a runtime dependency, so it's only added by default to the
devshell.

### `name_override = (cargoToml.package.name)`

Allows overriding the name from the `Cargo.toml` file.

## Special situations

### Different systems

Use the `nix-systems` flakes and set this to override the systems that
rust-flake will create outputs for:

```nix
{
  # ...
  inputs.systems.url = "github:nix-systems/default-linux";
  inputs.rust-flakes.inputs.systems.follows = "systems";
  # ...
}
```

This will only create outputs for `x86_64-linux` and `aarch64-linux`, not
`*-darwin`.
