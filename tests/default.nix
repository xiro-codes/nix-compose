{
  pkgs,
  lib-compose,
}:
let
  inherit (pkgs) lib;

  # A dummy composition for testing
  testCompose = lib-compose.mkCompose {
    name = "test-cluster";
    nodes = {
      node1 = { ... }: { };
      node2 = { ... }: { };
    };
  };

  # Evaluate for current system
  eval = testCompose.perSystem pkgs;

in
{
  # Basic evaluation check
  evaluation = pkgs.runCommand "test-evaluation" { } ''
    echo "Checking composition name..."
    [[ "${testCompose.name}" == "test-cluster" ]]

    echo "Checking node evaluation..."
    [[ -d "${eval.nodes'.node1}" ]]
    [[ -d "${eval.nodes'.node2}" ]]

    echo "Checking app and package generation..."
    [[ -x "${eval.apps.test-cluster.program}" ]]
    [[ -d "${eval.packages.test-cluster}" ]]

    touch $out
  '';

  # NixOS Module evaluation check
  module =
    let
      nixosEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        inherit (pkgs) system;
        modules = [
          testCompose.nixosModule
          {
            nxc.compose.test-cluster.enable = true;
            # Provide a minimal bootloader/fileSystem so it evaluates
            fileSystems."/" = {
              device = "/dev/null";
            };
            boot.loader.grub.enable = false;
          }
        ];
      };
    in
    pkgs.runCommand "test-module" { buildInputs = [ pkgs.jq ]; } ''
      echo "Checking bridge configuration..."
      [[ "${builtins.toString nixosEval.config.networking.bridges.br-test-cluster.interfaces}" == "" ]]
      
      echo "Checking container paths..."
      # The container name should now be node1-<hash>
      # Extract the path via jq from a JSON-ified map of all container paths
      CONTAINER_PATH=$(echo '${builtins.toJSON (builtins.mapAttrs (_: v: v.path) nixosEval.config.containers)}' | jq -r 'to_entries[] | select(.key | startswith("node1-")) | .value')
      
      echo "Found container path: $CONTAINER_PATH"
      [[ -n "$CONTAINER_PATH" ]]
      [[ -d "$CONTAINER_PATH" ]]
      
      touch $out
    '';

  # Collision test: ensure two compositions with same node names don't collide
  collision =
    let
      c1 = lib-compose.mkCompose {
        name = "cluster1";
        nodes = { web = { ... }: { }; };
      };
      c2 = lib-compose.mkCompose {
        name = "cluster2";
        nodes = { web = { ... }: { }; };
      };
      nixosEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        inherit (pkgs) system;
        modules = [
          c1.nixosModule
          c2.nixosModule
          {
            nxc.compose.cluster1.enable = true;
            nxc.compose.cluster2.enable = true;
            fileSystems."/" = { device = "/dev/null"; };
            boot.loader.grub.enable = false;
          }
        ];
      };
    in
    pkgs.runCommand "test-collision" { buildInputs = [ pkgs.jq ]; } ''
      echo "Checking that both 'web' containers exist with different names..."
      CONTAINER_COUNT=$(echo '${builtins.toJSON (builtins.attrNames nixosEval.config.containers)}' | jq '. | length')
      if [[ "$CONTAINER_COUNT" != "2" ]]; then
        echo "Error: Expected 2 containers, found $CONTAINER_COUNT"
        echo "Containers: ${builtins.toJSON (builtins.attrNames nixosEval.config.containers)}"
        exit 1
      fi
      touch $out
    '';
}
