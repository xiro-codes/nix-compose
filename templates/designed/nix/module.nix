{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.app;
  pkg = self.packages.${pkgs.system}.default;
in
{
  options.services.app = {
    enable = mkEnableOption "Web Service";

    package = mkOption {
      type = types.package;
      default = pkg;
      description = "The package to use for the services.";
    };

    secretKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing ROCKET_SECRET_KEY=... for session encryption.";
    };

    databaseUrl = mkOption {
      type = types.str;
      default = "postgres://rocket_blog:rocket_blog@localhost/rocket_blog";
      description = "Database connection string.";
    };

    workingDirectory = mkOption {
      type = types.str;
      default = "${cfg.package}/share/rocket-blog";
      description = "Working directory for the services. Override this for development to point to local templates/static.";
    };

    port = mkOption {
      type = types.port;
      default = 8000;
      description = "Port for the unified Rocket Forge service.";
    };

    domain = mkOption {
      type = types.str;
      default = "_";
      description = "Domain name for the nginx virtual host.";
    };

  };

  config = mkIf cfg.enable {
    systemd.services.rocket-forge = {
      description = "Rocket Forge Unified Service";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
      ];
      environment = {
        ROCKET_PROFILE = cfg.rocketProfile;
        ROCKET_PORT = toString cfg.port;
        ROCKET_ADDRESS = "0.0.0.0";
        ROCKET_DATABASES__SEA_ORM__URL = cfg.databaseUrl;
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/app";
        WorkingDirectory = cfg.workingDirectory;
        EnvironmentFile = mkIf (cfg.secretKeyFile != null) cfg.secretKeyFile;
        Restart = "always";
        DynamicUser = true;
      };
    };

    networking.firewall.allowedTCPPorts = [ 80 ];

    services.nginx = {
      enable = true;
      virtualHosts."${cfg.domain}" = {
        default = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };
    };
  };
}
