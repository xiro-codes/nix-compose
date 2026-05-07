{
  description = "Pure Nix Compose - A library for multi-node NixOS VM orchestration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-schemas.url = "github:DeterminateSystems/flake-schemas";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      flake-schemas,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Use standard schemas plus custom ones for our unique outputs
      flake.schemas = flake-schemas.schemas // {
        lib = {
          version = 1;
          doc = "Custom library functions for Pure Nix Compose";
          inventory = self: {
            children = builtins.mapAttrs (name: _: {
              forSystems = [ ];
              what = "library function";
            }) (import ./lib/compose.nix);
          };
        };
      };

      # Top-level library and templates
      flake.lib = import ./lib/compose.nix;

      flake.templates = {
        default = self.templates.basic;
        basic = {
          path = ./templates/basic;
          description = "A basic multi-node NixOS cluster using Pure Nix Compose";
        };
      };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        {
          # Default formatter
          formatter = pkgs.nixfmt-tree;

          # Development shell for library maintenance
          devShells.default = pkgs.mkShellNoCC {
            packages = [
              pkgs.nixfmt-tree
            ];
            shellHook = ''
              echo "Pure Nix Compose Library"
              echo "------------------------"
              echo "To create a new cluster from the template:"
              echo "  mkdir my-cluster && cd my-cluster"
              echo "  nix flake init -t .#basic"
            '';
          };
        };
    };
}
