{
  description = "A basic multi-node NixOS cluster using Pure Nix Compose";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-compose.url = "github:xiro-codes/nix-compose";
    flake-schemas.url = "github:DeterminateSystems/flake-schemas";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      nix-compose,
      ...
    }:
    let
      composition = import ./nix/composition.nix {
        inherit self;
        inherit (inputs) nix-compose;
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
      ];
      flake = composition.flake;
      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        let
          # Evaluate the composition for the current system
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import inputs.rust-overlay) ];
          };
          rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [
              "rust-src"
              "rust-analyzer"
            ];
          };
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };
          app = pkgs.callPackage ((import ./nix/package.nix) { name = "app"; }) {
            inherit rustPlatform;
          };
          comp = composition.perSystem pkgs;
        in
        {
          apps.default = comp.apps."${composition.name}";
          packages =
            comp.packages
            // comp.nodes' # maybe i shouldnt outputs these as packages
            // {
              default = app.overrideAttrs (old: {
                buildType = "debug";
              });
              app = app.overrideAttrs (old: {
                buildType = "debug";
              });
              app-release = app;
            };
          formatter = pkgs.nixfmt-tree;
          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [
              rustToolchain
              pkgs.pkg-config
            ];
            buildInputs = [
              pkgs.openssl
            ];
            packages = with pkgs; [
              sea-orm-cli
              just
            ];
            shellHook = ''
              echo "Rust + Nix + Compose Dev Environment"
              echo "Rust: $(rustc --version)"
            '';
          };
        };

    };
}
