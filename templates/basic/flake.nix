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
            name = "cl";
            nodes = {
              srv =
                { ... }:
                {
                  services.nginx = {
                    enable = true;
                    virtualHosts.default = {
                      default = true;
                      locations."/".return = "200 'Hello World'";
                    };
                  };
                  networking.firewall.allowedTCPPorts = [ 80 ];
                };
              clt =
                { pkgs, ... }:
                {
                  environment.systemPackages = [ pkgs.curl ];
                };
            };
          };
        in
        {
          inherit (composition.flake) nixosContainers nixosModules;

          # Export the 'nxc' CLI app
          apps.default = nix-compose.lib.mkApp {
            inherit pkgs system;
            inherit composition;
          };

          # Export individual VM packages for building
          packages = {
            default = composition.nodes.srv;
          } // composition.nodes;

          devShells.default = pkgs.mkShellNoCC {
            packages = [ pkgs.just ];
            shellHook = ''
              echo "Nix-Compose Template Shell (Container Backend)"
              echo "----------------------------------------------"
              echo "Available commands:"
              echo "  nix run . up          - Start the containers (requires sudo)"
              echo "  nix run . down        - Stop and destroy containers"
              echo "  nix run . shell srv     - Enter the 'srv' container"
              echo "  nix run . status      - Show cluster status"
              echo "  just build            - Build all container toplevels"
            '';
          };
        };
    };
}
