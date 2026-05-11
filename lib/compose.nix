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
    }:
    { config, pkgs, ... }:
    let
      inherit (pkgs.lib) concatStringsSep mapAttrsToList;
      activationScript = pkgs.substituteAll {
        src = ../pkgs/dev/activation.sh;
        devPublicKey = devKeys.public;
      };
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
      networking.defaultGateway = "10.233.1.254";

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
      system.activationScripts.vmuser-ssh-keys = builtins.readFile activationScript;

      # Inject cluster hosts via NixOS configuration
      networking.extraHosts = concatStringsSep "\n" (
        mapAttrsToList (n: ip: "${ip} ${n}") internalIps
      );
    };

  # Helper to create a package for a composition CLI
  mkPackage =
    {
      pkgs,
      composition,
    }:
    let
      inherit (pkgs) lib;
      inherit (lib) mapAttrs;

      nxcScript = pkgs.substituteAll {
        src = ../pkgs/nxc/nxc.sh;
        connectInfoJSON = builtins.toJSON composition.connectInfo;
        internalIpsJSON = builtins.toJSON composition.internalIps;
        nodesJSON = builtins.toJSON (mapAttrs (n: v: "${v}") composition.nodes);
        clusterName = composition.name;
        nixosContainer = "${pkgs.nixos-container}/bin/nixos-container";
        nixpkgsPath = pkgs.path;
      };
    in
    pkgs.writeShellApplication {
      name = "nxc-${composition.name}";
      runtimeInputs = [
        pkgs.nix
        pkgs.iproute2
        pkgs.openssh
        pkgs.jq
        pkgs.procps
        pkgs.iptables
      ];
      text = builtins.readFile nxcScript;
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
      inherit (lib)
        mapAttrs
        stringLength
        imap0
        attrNames
        listToAttrs
        nameValuePair
        findFirst
        substring
        mapAttrsToList
        concatStringsSep
        ;

      # Enforce name limits for nixos-container (interface names are limited to 15 chars, so 've-' + name <= 15)
      maxLen = 12;
      validateNames = mapAttrs (
        nodeName: _:
        let
          fullPath = "${name}-${nodeName}";
        in
        if stringLength fullPath > maxLen then
          throw "Container name '${fullPath}' is too long (${toString (stringLength fullPath)} chars). NixOS container names (including the composition name) must be <= ${toString maxLen} characters to satisfy network interface limits."
        else
          null
      ) nodes;

      # Assign an SSH port to each node starting from 2222
      nodesWithPorts = imap0 (i: name: {
        inherit name;
        sshPort = 2222 + i;
      }) (attrNames nodes);

      # Internal IP mapping (using 10.233.1.x subnet)
      internalIps = listToAttrs (
        imap0 (i: n: nameValuePair n "10.233.1.${toString (i + 1)}") (attrNames nodes)
      );

      # Helper to evaluate NixOS configurations
      nixosSystem = import (pkgs.path + "/nixos/lib/eval-config.nix");

      # Evaluate each node as a proper NixOS system
      evaluatedNodes = mapAttrs (
        nodeName: nodeConf:
        let
          _ = validateNames.${nodeName};
        in
        nixosSystem {
          inherit (pkgs) system;
          modules = [
            nodeConf
            (mkDevModule {
              inherit internalIps nodes;
              name = nodeName;
              sshPort = (findFirst (n: n.name == nodeName) { } nodesWithPorts).sshPort or 2222;
            })
          ];
        }
      ) nodes;

      nodes' = mapAttrs (_: node: node.config.system.build.toplevel) evaluatedNodes;

      bridgeName = "br-${substring 0 12 name}";

      # A NixOS module that can be imported into system dotfiles
      nixosModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.containers.compose.${name};
          inherit (lib)
            mkEnableOption
            mkOption
            mkIf
            types
            mapAttrs
            mapAttrsToList
            concatStringsSep
            ;

          # If extraModules are provided, we must re-evaluate the nodes.
          # Otherwise, we use the pre-evaluated nodes' to save time.
          currentNodes =
            if cfg.extraModules == [ ] then
              nodes'
            else
              mapAttrs (
                nodeName: nodeConf:
                (nixosSystem {
                  inherit (pkgs) system;
                  modules = [
                    nodeConf
                    (mkDevModule {
                      inherit internalIps nodes;
                      name = nodeName;
                      sshPort = (findFirst (n: n.name == nodeName) { } nodesWithPorts).sshPort or 2222;
                    })
                  ] ++ cfg.extraModules;
                }).config.system.build.toplevel
              ) nodes;
        in
        {
          options.containers.compose."${name}" = {
            enable = mkEnableOption "Nix-Compose cluster ${name}";
            bridgeIp = mkOption {
              type = types.str;
              default = "10.233.1.254";
              description = "The IP address for the host bridge interface.";
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

            containers = mapAttrs (nodeName: toplevel: {
              path = toplevel;
              autoStart = true;
              privateNetwork = true;
              hostBridge = bridgeName;
            }) currentNodes;

            networking.extraHosts = concatStringsSep "\n" (
              mapAttrsToList (n: ip: "${ip} ${n}") internalIps
            );
          };
        };

      res = {
        inherit name nixosModule bridgeName internalIps;
        nodes = nodes';

        # A summary of how to connect
        connectInfo = listToAttrs (
          map ({ name, sshPort }: nameValuePair name { inherit sshPort; }) nodesWithPorts
        );

        # Standardized flake outputs for this composition
        flake = {
          nixosModules = { "${name}" = nixosModule; default = nixosModule; };
          nixosContainers."${name}" = nodes';
          packages."${pkgs.system}"."${name}" = mkPackage { inherit pkgs; composition = res; };
        };
      };
    in
    res;
in
{
  inherit mkComposition mkPackage mkApp;
}
