{
  self,
  nix-compose,
}:

nix-compose.lib.mkCompose {
  name = "forge";
  subnet = "1.233.2";
  nodes = {
    app =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        services.rocket-forge = {
          enable = true;
          databaseUrl = "postgres://rocket_blog:rocket_blog@db/rocket_blog";
          redisUrl = "redis://redis/";
          secretKeyFile = ../.rocket_secret_key;
        };
        networking.firewall.allowedTCPPorts = [ 80 ];
      };
    db =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        services.rocket-forge = {
          enable = false;
          manageDatabase = true;
        };
      };
    redis =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        services.rocket-forge = {
          enable = false;
          manageRedis = true;
        };
      };
  };
  nodeConfig = {
    db = {
      order = 10;
    };
    redis = {
      order = 10;
    };
    app = {
      order = 20;
    };
  };
}
