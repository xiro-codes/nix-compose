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

  # Ordering test
  ordering =
    let
      c = lib-compose.mkCompose {
        name = "ordered-cluster";
        nodes = {
          node1 = { ... }: { };
          node2 = { ... }: { };
        };
        nodeConfig = {
          node1 = { order = 2; };
          node2 = { order = 1; };
        };
      };
      eval = c.perSystem pkgs;
    in
    pkgs.runCommand "test-ordering" { buildInputs = [ pkgs.jq ]; } ''
      echo "Checking if node2 comes before node1 in the package's nxc script..."
      SCRIPT_CONTENT=$(cat ${eval.packages.ordered-cluster}/bin/nxc-ordered-cluster)
      ORDERED_NODES=$(echo "$SCRIPT_CONTENT" | grep "ORDERED_NODES=" | cut -d"'" -f2)
      FIRST_NODE=$(echo "$ORDERED_NODES" | jq -r '.[0]')
      if [[ "$FIRST_NODE" != "node2" ]]; then
        echo "Error: Expected node2 first, found $FIRST_NODE"
        echo "Ordered nodes: $ORDERED_NODES"
        exit 1
      fi
      touch $out
    '';

  # autoStart test
  autostart =
    let
      c = lib-compose.mkCompose {
        name = "autostart-cluster";
        nodes = {
          node1 = { ... }: { };
          node2 = { ... }: { };
        };
      };
      nixosEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        inherit (pkgs) system;
        modules = [
          c.nixosModule
          {
            nxc.compose.autostart-cluster = {
              enable = true;
              autoStart = false;
              nodes.node1.autoStart = true;
            };
            fileSystems."/" = { device = "/dev/null"; };
            boot.loader.grub.enable = false;
          }
        ];
      };
    in
    pkgs.runCommand "test-autostart" { buildInputs = [ pkgs.jq ]; } ''
      echo "Checking container autoStart settings..."
      # Extract attributes to find hashed names
      NODES_JSON='${builtins.toJSON (builtins.mapAttrs (n: v: v.autoStart) nixosEval.config.containers)}'
      
      NODE1_VAL=$(echo "$NODES_JSON" | jq -r 'to_entries[] | select(.key | startswith("node1-")) | .value')
      NODE2_VAL=$(echo "$NODES_JSON" | jq -r 'to_entries[] | select(.key | startswith("node2-")) | .value')
      
      echo "node1 autoStart: $NODE1_VAL"
      echo "node2 autoStart: $NODE2_VAL"
      
      [[ "$NODE1_VAL" == "true" ]]
      [[ "$NODE2_VAL" == "false" ]]
      
      touch $out
    '';
}
