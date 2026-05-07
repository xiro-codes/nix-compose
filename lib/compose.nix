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
      # Container specific settings
      boot.isContainer = true;

      # Enable SSH for remote access (optional but nice)
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
        user = "vmuser";
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

      # Explicitly ensure all nodes are in /etc/hosts
      networking.hosts = lib.listToAttrs (
        lib.imap0 (i: n: lib.nameValuePair "10.233.1.${toString (i + 1)}" [ n ]) (lib.attrNames nodes)
      );
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

      # Create the NixOS test which acts as our evaluator
      test = pkgs.testers.nixosTest {
        inherit name testScript;
        nodes = enrichedNodes;
      };
    in
    {
      inherit test name;
      driver = test.driver;

      # Export individual container toplevels
      nodes = lib.mapAttrs (name: node: node.config.system.build.toplevel) test.nodes;

      # A summary of how to connect
      connectInfo = lib.listToAttrs (
        map ({ name, sshPort }: lib.nameValuePair name { inherit sshPort; }) nodesWithPorts
      );

      # Internal IP mapping for the CLI (using 10.233.1.x subnet often used for containers)
      internalIps = lib.listToAttrs (
        lib.imap0 (i: n: lib.nameValuePair n "10.233.1.${toString (i + 1)}") (lib.attrNames nodes)
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
      connectInfoJSON = builtins.toJSON composition.connectInfo;
      internalIpsJSON = builtins.toJSON composition.internalIps;
      nodesJSON = builtins.toJSON (lib.mapAttrs (n: v: "${v}") composition.nodes);
      clusterName = composition.name;
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
            pkgs.nixos-container
          ];
          text = ''
            COMMAND="''${1:-help}"
            [ "$#" -gt 0 ] && shift

            CONNECT_INFO='${connectInfoJSON}'
            INTERNAL_IPS='${internalIpsJSON}'
            NODES='${nodesJSON}'
            CLUSTER_NAME="${clusterName}"

            case "$COMMAND" in
              up)
                echo "Starting NixOS containers for cluster: $CLUSTER_NAME"
                echo "$NODES" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r NODE TOPLEVEL; do
                  CONTAINER_NAME="$CLUSTER_NAME-$NODE"
                  echo "  - Starting $NODE ($CONTAINER_NAME)..."
                  
                  if sudo nixos-container list | grep -q "^$CONTAINER_NAME$"; then
                    sudo nixos-container update "$CONTAINER_NAME" --system "$TOPLEVEL"
                  else
                    sudo nixos-container create "$CONTAINER_NAME" --system "$TOPLEVEL"
                  fi
                  sudo nixos-container start "$CONTAINER_NAME"
                done
                echo "Cluster is up. Use 'nxc status' to monitor."
                ;;
              down)
                echo "Stopping and destroying NixOS containers..."
                echo "$NODES" | jq -r 'keys[]' | while read -r NODE; do
                  CONTAINER_NAME="$CLUSTER_NAME-$NODE"
                  echo "  - Stopping $CONTAINER_NAME..."
                  sudo nixos-container stop "$CONTAINER_NAME" || true
                  sudo nixos-container destroy "$CONTAINER_NAME" || true
                done
                ;;
              ssh)
                NODE="''${1:-}"
                if [ -z "$NODE" ]; then
                  echo "Usage: nxc ssh <node-name>"
                  exit 1
                fi
                CONTAINER_NAME="$CLUSTER_NAME-$NODE"
                
                if ! sudo nixos-container list | grep -q "^$CONTAINER_NAME$"; then
                  echo "Error: Container $CONTAINER_NAME is not running."
                  exit 1
                fi

                echo "Connecting to ''${NODE} via nixos-container run..."
                sudo nixos-container run "$CONTAINER_NAME" -- login -f vmuser
                ;;
              list)
                echo "Configured Nodes:"
                echo "$CONNECT_INFO" | jq -r 'keys[]' | sed 's/^/- /'
                ;;
              ip)
                NODE="''${1:-}"
                if [ -z "$NODE" ]; then
                  echo "Usage: nxc ip <node-name>"
                  exit 1
                fi
                IP=$(echo "$INTERNAL_IPS" | jq -r ".\"''${NODE}\" // empty")
                if [ -z "$IP" ]; then
                  echo "Error: Unknown node ''${NODE}"
                  exit 1
                fi
                echo "$IP"
                ;;
              status)
                echo "Cluster Status ($CLUSTER_NAME):"
                sudo nixos-container list | grep "$CLUSTER_NAME-" || echo "No containers running for this cluster."
                ;;
              help|--help|-h)
                echo "Usage: nxc [COMMAND]"
                echo ""
                echo "Available commands:"
                echo "  up                       Start NixOS containers"
                echo "  down                     Stop and destroy containers"
                echo "  ssh <node>               Enter a node container"
                echo "  status                   Show the status of running containers"
                echo "  list                     List all configured nodes"
                echo "  ip <node>                Print the internal ip address of a node"
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
