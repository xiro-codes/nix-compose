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
      internalIps,
      bridgeIp,
    }:
    { config, pkgs, ... }:
    let
      inherit (pkgs.lib) concatStringsSep mapAttrsToList;
      activationScript = pkgs.writeText "activation.sh" (
        builtins.replaceStrings [ "@devPublicKey@" ] [ devKeys.public ] (
          builtins.readFile ../pkgs/dev/activation.sh
        )
      );
    in
    {
      # Container specific settings
      boot.isContainer = true;

      # Networking configuration
      networking.hostName = name;
      networking.useDHCP = false;
      networking.usePredictableInterfaceNames = false;
      networking.interfaces.eth0.ipv4.addresses = [
        {
          address = internalIps.${name};
          prefixLength = 24;
        }
      ];
      networking.defaultGateway = bridgeIp;

      # Allow all traffic on the internal interface for ease of use in the cluster
      networking.firewall.trustedInterfaces = [ "eth0" ];
      networking.firewall.checkReversePath = false;

      # Enable SSH for remote access (optional but nice)
      services.openssh.enable = true;
      services.openssh.settings.PermitRootLogin = "yes";

      # Create a default vmuser
      environment.systemPackages = [ pkgs.htop ];
      users.users.vmuser = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        initialPassword = ""; # No password for ease of use
        openssh.authorizedKeys.keys = [ devKeys.public ];
      };
      services.nginx = {
        commonHttpConfig = ''
          error_log syslog:server=unix:/dev/log;
          access_log syslog:server=unix:/dev/log combined;
        '';
      };
      # Allow passwordless sudo for vmuser
      security.sudo.wheelNeedsPassword = false;

      # Inject the private key so nodes can SSH into each other
      environment.etc."ssh/id_ed25519" = {
        text = devKeys.private;
        mode = "0600";
        user = "vmuser";
      };
      system.stateVersion = "26.05";
      # Fix permissions for the private key in the user's home
      system.activationScripts.vmuser-ssh-keys.text = builtins.readFile activationScript;

      # Inject cluster hosts via NixOS configuration
      networking.extraHosts = concatStringsSep "\n" (mapAttrsToList (n: ip: "${ip} ${n}") internalIps);
    };

  # Helper to create a package for a composition CLI
  mkPackage =
    {
      pkgs,
      composition,
    }:
    let
      inherit (pkgs) lib;
      inherit (lib) mapAttrs attrNames sort;

      orderedNodes = sort (a: b:
        (composition.nodeConfig.${a}.order or 1000) < (composition.nodeConfig.${b}.order or 1000)
      ) (attrNames composition.nodes');

      nxcScript = pkgs.writeText "nxc.py" (
        builtins.replaceStrings
          [
            "@connectInfoJSON@"
            "@internalIpsJSON@"
            "@nodesJSON@"
            "@orderedNodesJSON@"
            "@containerNamesJSON@"
            "@clusterName@"
            "@clusterHash@"
            "@bridgeIp@"
            "@nixosContainer@"
            "@nixpkgsPath@"
          ]
          [
            (builtins.toJSON composition.connectInfo)
            (builtins.toJSON composition.internalIps)
            (builtins.toJSON (mapAttrs (n: v: "${v}") composition.nodes'))
            (builtins.toJSON orderedNodes)
            (builtins.toJSON composition.containerNames)
            composition.name
            composition.clusterHash
            composition.bridgeIp
            "${pkgs.nixos-container}/bin/nixos-container"
            "${pkgs.path}"
          ]
          (builtins.readFile ../pkgs/nxc/nxc.py)
      );
    in
    pkgs.writeShellApplication {
      name = "nxc-${composition.name}";
      runtimeInputs = [
        pkgs.python3
        pkgs.nix
        pkgs.iproute2
        pkgs.openssh
        pkgs.jq
        pkgs.procps
        pkgs.iptables
      ];
      text = "${pkgs.python3}/bin/python3 ${nxcScript} \"$@\"";
    };

  # Helper to create a unified CLI app for a composition
  mkApp =
    {
      pkgs,
      composition,
    }:
    let
      inherit (pkgs.lib) getExe;
      pkg = mkPackage { inherit pkgs composition; };
    in
    {
      type = "app";
      program = getExe pkg;
    };

  # The main helper to create a composition (system-agnostic)
  mkCompose =
    {
      nodes,
      name ? "composition",
      autoStart ? true,
      nodeConfig ? { },
      subnet ? "10.233.1",
      bridgeIp ? "${subnet}.254",
    }:
    let
      # Helpers used during evaluation
      nixosSystem = pkgs: import (pkgs.path + "/nixos/lib/eval-config.nix");

      clusterHash = builtins.substring 0 4 (builtins.hashString "sha256" name);

      bridgeName = "br-${builtins.substring 0 12 name}";

      # Internal helper to evaluate nodes for a specific pkgs
      evaluate =
        pkgs:
        let
          inherit (pkgs) lib;
          inherit (lib)
            mapAttrs
            stringLength
            imap0
            attrNames
            listToAttrs
            nameValuePair
            findFirst
            ;

          # Generate unique container names (max 12 chars: shortNodeName(7) + '-' + hash(4))
          containerNames = mapAttrs (
            nodeName: _:
            let
              shortName = builtins.substring 0 7 nodeName;
            in
            "${shortName}-${clusterHash}"
          ) nodes;

          # Assign an SSH port to each node starting from 2222
          nodesWithPorts = imap0 (i: name: {
            inherit name;
            sshPort = 2222 + i;
          }) (attrNames nodes);

          # Internal IP mapping (using configured subnet)
          internalIps = listToAttrs (
            imap0 (i: n: nameValuePair n "${subnet}.${toString (i + 1)}") (attrNames nodes)
          );

          # Evaluate each node as a proper NixOS system
          evaluatedNodes = mapAttrs (
            nodeName: nodeConf: (nixosSystem pkgs) {
              inherit (pkgs) system;
              modules = [
                nodeConf
                (mkDevModule {
                  inherit internalIps nodes bridgeIp;
                  name = nodeName;
                  sshPort = (findFirst (n: n.name == nodeName) { } nodesWithPorts).sshPort or 2222;
                })
              ];
            }
          ) nodes;

          nodes' = mapAttrs (_: node: node.config.system.build.toplevel) evaluatedNodes;

          connectInfo = listToAttrs (
            map ({ name, sshPort }: nameValuePair name { inherit sshPort; }) nodesWithPorts
          );
        in
        {
          inherit
            nodes'
            connectInfo
            internalIps
            nodesWithPorts
            containerNames
            ;
        };

      # The NixOS module that can be imported into system dotfiles
      nixosModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.nxc.compose."${name}";
          inherit (lib)
            mkEnableOption
            mkOption
            mkIf
            types
            mapAttrs
            mapAttrsToList
            concatStringsSep
            listToAttrs
            ;

          # Evaluate nodes lazily based on host pkgs
          evalResult = evaluate pkgs;
          inherit (evalResult)
            internalIps
            nodes'
            containerNames
            ;

          # If extraModules are provided, we must re-evaluate the nodes.
          currentNodes =
            if cfg.extraModules == [ ] then
              nodes'
            else
              mapAttrs (
                nodeName: nodeConf:
                ((nixosSystem pkgs) {
                  inherit (pkgs) system;
                  modules = [
                    nodeConf
                    (mkDevModule {
                      inherit internalIps nodes;
                      bridgeIp = cfg.bridgeIp;
                      name = nodeName;
                      sshPort = (lib.findFirst (n: n.name == nodeName) { } evalResult.nodesWithPorts).sshPort or 2222;
                    })
                  ]
                  ++ cfg.extraModules;
                }).config.system.build.toplevel
              ) nodes;
        in
        {
          options.nxc.compose."${name}" = {
            enable = mkEnableOption "Nix-Compose cluster ${name}";
            bridgeIp = mkOption {
              type = types.str;
              default = bridgeIp;
              description = "The IP address for the host bridge interface.";
            };
            autoStart = mkOption {
              type = types.bool;
              default = true;
              description = "Whether to automatically start containers in this cluster on boot.";
            };
            nodes = mkOption {
              type = types.attrsOf (types.submodule {
                options = {
                  autoStart = mkOption {
                    type = types.nullOr types.bool;
                    default = null;
                    description = "Override the cluster-wide autoStart for this node.";
                  };
                  order = mkOption {
                    type = types.int;
                    default = 1000;
                    description = "Order in which this node starts (lower is earlier).";
                  };
                };
              });
              default = { };
              description = "Per-node configuration for this cluster.";
            };
            extraModules = mkOption {
              type = types.listOf types.unspecified;
              default = [ ];
              description = "Additional NixOS modules to inject into all nodes in this composition.";
            };
          };

          config = mkIf cfg.enable {
            networking.bridges."${bridgeName}".interfaces = [ ];
            networking.interfaces."${bridgeName}".ipv4.addresses = [
              {
                address = cfg.bridgeIp;
                prefixLength = 24;
              }
            ];
            networking.firewall.trustedInterfaces = [ bridgeName ];

            containers = listToAttrs (
              mapAttrsToList (nodeName: toplevel: {
                name = containerNames.${nodeName};
                value = {
                  path = toplevel;
                  autoStart =
                    let
                      nodeAutoStart = if cfg.nodes ? ${nodeName} then cfg.nodes.${nodeName}.autoStart else null;
                    in
                    if nodeAutoStart != null then nodeAutoStart else cfg.autoStart;
                  privateNetwork = true;
                  hostBridge = bridgeName;
                };
              }) currentNodes
            );

            networking.extraHosts = concatStringsSep "\n" (
              mapAttrsToList (n: ip: "${ip} ${n} ${n}.${name} ${containerNames.${n}}") internalIps
            );
          };
        };
    in
    rec {
      inherit name nodes nixosModule;

      # Function to get per-system outputs
      perSystem =
        pkgs:
        let
          evalResult = evaluate pkgs;
          inherit (evalResult)
            nodes'
            connectInfo
            internalIps
            containerNames
            ;

          composition = {
            inherit
              name
              nodes'
              connectInfo
              internalIps
              containerNames
              clusterHash
              nodeConfig
              bridgeIp
              ;
          };

          pkg = mkPackage { inherit pkgs composition; };
          app = mkApp { inherit pkgs composition; };
        in
        {
          inherit nodes' composition;
          packages."${name}" = pkg;
          apps."${name}" = app;
        };

      # Standardized flake outputs (some are system-agnostic)
      flake = {
        nixosModules = {
          "${name}" = nixosModule;
          default = nixosModule;
        };
      };
    };
in
{
  inherit
    mkCompose
    mkPackage
    mkApp
    ;
  # Compatibility alias
  mkComposition = mkCompose;
}
