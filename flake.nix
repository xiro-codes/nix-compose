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
      # Only export schemas for the fields we actually use
      flake.schemas = {
        inherit (flake-schemas.schemas)
          apps
          packages
          devShells
          templates
          nixosModules
          formatter
          schemas
          checks
          ;

        lib = {
          version = 1;
          doc = "Custom library functions for Nix Compose";
          inventory = self: {
            children = builtins.mapAttrs (name: _: {
              forSystems = [ ];
              what = "library function";
            }) (import ./lib/compose.nix);
          };
        };

        nixosContainers = {
          version = 1;
          doc = "NixOS containers defined by nix-compose";
          inventory = self: {
            children = builtins.mapAttrs (system: clusters: {
              what = "system";
              children = builtins.mapAttrs (clusterName: cluster: {
                what = "NixOS Container Cluster";
                children = builtins.mapAttrs (nodeName: node: {
                  what = "NixOS Container Node";
                  derivation = node;
                }) cluster;
              }) clusters;
            }) (self.nixosContainers or { });
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
        designed = {
          path = ./templates/designed;
          description = "The more intended usage";
        };
      };

      systems = [
        "x86_64-linux"
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

          # Flake checks for CI/Verification
          checks = import ./tests {
            inherit pkgs;
            lib-compose = self.lib;
          };

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
