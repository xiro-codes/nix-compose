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
    pkgs.runCommand "test-module" { } ''
      echo "Checking bridge configuration..."
      [[ "${builtins.toString nixosEval.config.networking.bridges.br-test-cluster.interfaces}" == "" ]]
      
      echo "Checking container paths..."
      [[ -d "${nixosEval.config.containers.node1.path}" ]]
      
      touch $out
    '';
}
