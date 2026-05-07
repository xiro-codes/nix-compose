{
  description = "A basic multi-node NixOS cluster using Pure Nix Compose";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-compose.url = "github:xiro-codes/nix-compose";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      nix-compose,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
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
        let
          # Define your cluster nodes here
          composition = nix-compose.lib.mkComposition {
            inherit pkgs;
            name = "my-cluster";
            nodes = {
              server =
                { ... }:
                {
                  services.nginx = {
                    enable = true;
                    virtualHosts.default = {
                      default = true;
                      locations."/".return = "200 'OK'";
                    };
                  };
                  networking.firewall.allowedTCPPorts = [ 80 ];
                };
              client =
                { pkgs, ... }:
                {
                  environment.systemPackages = [ pkgs.curl ];
                };
            };
          };
        in
        {
          # Export the 'nxc' CLI app
          apps.default = nix-compose.lib.mkApp {
            inherit pkgs system;
            inherit composition;
          };

          # Export individual VM packages for building
          packages = {
            default = composition.driver;
          }
          // composition.nodes;

          devShells.default = pkgs.mkShellNoCC {
            packages = [ pkgs.just ];
            shellHook = ''
              echo "Nix-Compose Template Shell"
              echo "--------------------------"
              echo "Available commands:"
              echo "  nix run . up          - Start the cluster (non-interactive)"
              echo "  nix run . up -i       - Start the cluster with interactive REPL"
              echo "  nix run . ssh server  - SSH into 'server'"
              echo "  just build            - Build all VMs"
            '';
          };
        };
    };
}
