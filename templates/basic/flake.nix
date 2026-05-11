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
    let
      # Define your cluster composition at the top level
      cluster = nix-compose.lib.mkCompose {
        name = "nxc-basic";
        nodes = {
          server =
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
          client =
            { pkgs, ... }:
            {
              environment.systemPackages = [ pkgs.curl ];
            };
        };
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
      ];

      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        let
          # Evaluate the composition for the current system
          comp = cluster.perSystem pkgs;
        in
        {
          # Export the 'nxc' CLI app
          apps.default = comp.apps."${cluster.name}";

          # Export individual VM packages for building
          packages = comp.packages // comp.nodes';

          devShells.default = pkgs.mkShellNoCC {
            packages = [ pkgs.just ];
            shellHook = ''
              echo "Nix-Compose Template Shell (Container Backend)"
              echo "----------------------------------------------"
              echo "Available commands:"
              echo "  nix run . up          - Start the containers (requires sudo)"
              echo "  nix run . down        - Stop and destroy containers"
              echo "  nix run . shell srv   - Enter the 'srv' container"
              echo "  nix run . status      - Show cluster status"
              echo "  just build            - Build all container toplevels"
            '';
          };
        };

      flake = nix-compose.schemas // cluster.flake
    };
}
