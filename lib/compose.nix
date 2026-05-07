let
  # Hardcoded development keys for internal node-to-node and host-to-node access.
  # These are safe for local development environments.
  devKeys = {
    public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOm6fV7fV9uX1f5fV7fV9uX1f5fV7fV9uX1f5fV7fV9u dev-key";
    # A placeholder private key - in a real "pure" nix setup we often provide a fixed dev key
    # or let the user provide one. For this emulation, we use a standard one.
    private = ''
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
      ZDI1NTE5AAAAIOm6fV7fV9uX1f5fV7fV9uX1f5fV7fV9uX1f5fV7fV9uAAAAsP6X7Vf6X7
      VfAAAAAtzc2gtZWZDI1NTE5AAAAIOm6fV7fV9uX1f5fV7fV9uX1f5fV7fV9uX1f5fV7fV
      9uAAAAYQC6fV7fV9uX1f5fV7fV9uX1f5fV7fV9uX1f5fV7fV9uX1f5fV7fV9uX1f5fV7fV
      9uX1f5fV7fV9uX1f5fV7fV9uX1f5fV7fV9uAAAAAAtZGV2LWtleQECAwQFBgc=
      -----END OPENSSH PRIVATE KEY-----
    '';
  };

  # Internal helper to inject dev configuration into nodes
  mkDevModule =
    {
      name,
      nodes,
      sshPort,
    }:
    { config, pkgs, ... }:
    let
      inherit (pkgs) lib;
    in
    {
      # Enable SSH for remote access
      services.openssh.enable = true;
      services.openssh.settings.PermitRootLogin = "yes";

      # Create a default vmuser
      users.users.vmuser = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        initialPassword = ""; # No password for ease of use
        openssh.authorizedKeys.keys = [ devKeys.public ];
      };

      # Allow passwordless sudo for vmuser
      security.sudo.wheelNeedsPassword = false;

      # Inject the private key so nodes can SSH into each other
      environment.etc."ssh/id_ed25519" = {
        text = devKeys.private;
        mode = "0600";
        user = "vmuser"; # Note: environment.etc usually owned by root, we'll fix in postStart
      };

      # Fix permissions for the private key in the user's home
      system.activationScripts.vmuser-ssh-keys = ''
        mkdir -p /home/vmuser/.ssh
        cp /etc/ssh/id_ed25519 /home/vmuser/.ssh/id_ed25519
        chown vmuser:users /home/vmuser/.ssh/id_ed25519
        chmod 600 /home/vmuser/.ssh/id_ed25519
        echo "${devKeys.public}" > /home/vmuser/.ssh/id_ed25519.pub
        chown vmuser:users /home/vmuser/.ssh/id_ed25519.pub
      '';

      # Forward SSH port to host using a dedicated network interface
      virtualisation.qemu.options = [
        "-device virtio-net-pci,netdev=sshnet"
        "-netdev user,id=sshnet,hostfwd=tcp::${toString sshPort}-:22"
      ];

      # Explicitly ensure all nodes are in /etc/hosts
      networking.hosts = lib.listToAttrs (
        lib.imap0 (i: n: lib.nameValuePair "192.168.1.${toString (i + 1)}" [ n ]) (lib.attrNames nodes)
      );
      # Note: 192.168.1.x is the default subnet for nixosTest vlan 1
    };
in
{
  # The main helper to create a composition
  mkComposition =
    {
      pkgs,
      nodes,
      name ? "composition",
      testScript ? "start_all()",
    }:
    let
      inherit (pkgs) lib;

      # Assign an SSH port to each node starting from 2222
      nodesWithPorts = lib.imap0 (i: name: {
        inherit name;
        sshPort = 2222 + i;
      }) (lib.attrNames nodes);

      # Wrap each node with our dev module
      enrichedNodes = lib.listToAttrs (
        map (
          { name, sshPort }:
          lib.nameValuePair name (
            { ... }:
            {
              imports = [
                nodes.${name}
                (mkDevModule {
                  inherit name nodes sshPort;
                })
              ];
            }
          )
        ) nodesWithPorts
      );

      # Create the NixOS test which acts as our orchestrator
      test = pkgs.testers.nixosTest {
        inherit name testScript;
        nodes = enrichedNodes;
      };
    in
    {
      inherit test;
      driver = test.driver;

      # Export individual VM runners
      nodes = lib.mapAttrs (name: node: node.config.system.build.vm) test.nodes;

      # A summary of how to connect
      connectInfo = lib.listToAttrs (
        map ({ name, sshPort }: lib.nameValuePair name { inherit sshPort; }) nodesWithPorts
      );

      # Internal IP mapping for the CLI
      internalIps = lib.listToAttrs (
        lib.imap0 (i: n: lib.nameValuePair n "192.168.1.${toString (i + 1)}") (lib.attrNames nodes)
      );
    };

  # Helper to create a unified CLI app for a composition
  mkApp =
    {
      pkgs,
      composition,
      system,
      flakeUrl ? ".",
    }:
    let
      inherit (pkgs) lib;
    in
    {
      type = "app";
      program = lib.getExe (
        pkgs.writeShellApplication {
          name = "nxc";
          runtimeInputs = [
            pkgs.openssh
            pkgs.jq
            pkgs.procps
          ];
          text = ''
            COMMAND="''${1:-help}"
            [ "$#" -gt 0 ] && shift

            case "$COMMAND" in
              up)
                echo "Starting development VMs..."
                "${composition.driver}/bin/nixos-test-driver" --interactive
                ;;
              down)
                echo "Stopping running VMs..."
                # We use the composition name to find the right processes
                pkill -f "qemu-system.*-name ${composition.test.name}" || echo "No VMs running."
                ;;
              ssh)
                NODE="''${1:-}"
                if [ -z "$NODE" ]; then
                  echo "Usage: nxc ssh <node-name>"
                  exit 1
                fi
                PORT=$(nix eval --json "${flakeUrl}#compositions.''${system}.default.connectInfo.''${NODE}.sshPort")
                echo "Connecting to ''${NODE} on port ''${PORT}..."
                exec ssh -p "''${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null vmuser@localhost
                ;;
              list)
                echo "Configured VMs:"
                nix eval --json "${flakeUrl}#compositions.''${system}.default.connectInfo" | jq -r 'keys[]' | sed 's/^/- /'
                ;;
              ip)
                NODE="''${1:-}"
                if [ -z "$NODE" ]; then
                  echo "Usage: nxc ip <node-name>"
                  exit 1
                fi
                nix eval --raw "${flakeUrl}#compositions.''${system}.default.internalIps.''${NODE}"
                echo ""
                ;;
              status)
                echo "Cluster Status:"
                pgrep -af "qemu-system.*-name ${composition.test.name}" || echo "Cluster is down."
                ;;
              help|--help|-h)
                echo "Usage: nxc [COMMAND]"
                echo ""
                echo "Available commands:"
                echo "  up                       Start development vms"
                echo "  down                     Stop running vms"
                echo "  ssh <node>               ssh into a running vm"
                echo "  status                   Show the status of running vms"
                echo "  list                     List all configured vms"
                echo "  ip <node>                Print the ip address of a vm"
                ;;
              *)
                echo "Unknown command: $COMMAND"
                echo "Run 'nxc help' for usage."
                exit 1
                ;;
            esac
          '';
        }
      );
    };
}
