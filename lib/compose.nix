let
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

      # Allow SSH traffic explicitly instead of trusting the entire interface
      networking.firewall.allowedTCPPorts = [ 22 ];
      networking.firewall.checkReversePath = false;

      # Enable SSH for remote access (optional but nice)
      services.openssh.enable = true;

      # Create a default vmuser
      environment.systemPackages = [ pkgs.htop ];
      users.users.vmuser = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        initialPassword = ""; # No password for ease of use
      };
      services.nginx = {
        commonHttpConfig = ''
          error_log syslog:server=unix:/dev/log;
          access_log syslog:server=unix:/dev/log combined;
        '';
      };
      system.stateVersion = "26.05";

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

      # Support both top-level composition objects and pre-evaluated data objects
      evalData = if composition ? perSystem then (composition.perSystem pkgs).composition else composition;

      orderedNodes = sort (a: b:
        (evalData.nodeConfig.${a}.order or 1000) < (evalData.nodeConfig.${b}.order or 1000)
      ) (attrNames evalData.nodes');
      nxcConfig = pkgs.writeText "config.json" (builtins.toJSON {
        connectInfo = evalData.connectInfo;
        internalIps = evalData.internalIps;
        nodes = mapAttrs (n: v: "${v}") evalData.nodes';
        orderedNodes = orderedNodes;
        containerNames = evalData.containerNames;
        clusterName = evalData.name;
        clusterHash = evalData.clusterHash;
        bridgeIp = evalData.bridgeIp;
        nixosContainer = "${pkgs.nixos-container}/bin/nixos-container";
        nixpkgsPath = "${pkgs.path}";
      });
    in
    pkgs.writeShellApplication {
      name = "nxc-${evalData.name}";
      runtimeInputs = [
        pkgs.python3
        pkgs.nix
        pkgs.iproute2
        pkgs.openssh
        pkgs.jq
        pkgs.procps
        pkgs.iptables
      ];
      text = ''
        export NXC_CONFIG="${nxcConfig}"
        ${pkgs.python3}/bin/python3 ${../pkgs/nxc/nxc.py} "$@"
      '';
    };

  # Helper to create a unified CLI app for a composition
  mkApp =
    {
      pkgs,
      composition,
    }:
    let
      inherit (pkgs.lib) getExe;
      pkg = mkPackage { inherit pkgs; composition = composition; };
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
      extraModules ? [ ],
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

          # Generate unique container names (max 11 chars due to veth limit)
          # Format: nc-HASH(8)
          containerNames = mapAttrs (
            nodeName: _:
            let
              hash = builtins.substring 0 8 (builtins.hashString "sha256" "${nodeName}-${clusterHash}");
            in
            "nc-${hash}"
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

      nixosModule' =
        { config, lib, pkgs, ... }:
        let
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
          cfg = config.nxc.compose."${name}";
          evalResult = evaluate pkgs;
          currentNodes = evalResult.nodes';
          inherit (evalResult) internalIps containerNames;
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

            environment.systemPackages = [
              (mkPackage {
                inherit pkgs;
                composition = topLevelComposition;
              })
            ];
          };
        };

      perSystem' =
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

          pkg = mkPackage { inherit pkgs; composition = composition; };
          app = mkApp { inherit pkgs; composition = composition; };
        in
        {
          inherit nodes' composition;
          packages."${name}" = pkg;
          apps."${name}" = app;
        };

      topLevelComposition = {
        inherit name nodes;
        nixosModule = nixosModule';
        perSystem = perSystem';
        flake = {
          nixosModules = {
            "${name}" = nixosModule';
            default = nixosModule';
          };
        };
      };
    in
    topLevelComposition;
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
