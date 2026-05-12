{
  name ? "app",
  self,
  nix-compose,
}:

nix-compose.lib.mkCompose {
  name = "${name}";
  subnet = "1.233.2";
  nodes = {
    app =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
        services."${name}" = {
          enable = true;
          databaseUrl = "postgres://${name}:${name}@db/${name}";
        };
        networking.firewall.allowedTCPPorts = [ 80 8000 ];
      };
    db =
      { ... }:
      {
        imports = [ self.nixosModules.default ];
      };
  };
  nodeConfig = {
    db = {
      order = 10;
    };
    app = {
      order = 20;
    };
  };
}
