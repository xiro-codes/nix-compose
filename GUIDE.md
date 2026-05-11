# Guide: Building a Multi-Node Rust Cluster with Nix-Compose

This guide walks you through setting up a professional multi-node development environment for a Rust application (based on the `rocket-forge` project). You will learn how to package a Rust app, create a NixOS module for it, and orchestrate a cluster with a dedicated database and cache.

## Step 1: Flake Infrastructure

Start by setting up your `flake.nix` with the necessary inputs for Rust development and orchestration.

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-compose.url = "github:xiro-codes/nix-compose";
  };

  outputs = inputs@{ nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      perSystem = { config, pkgs, system, ... }: {
        # Configure Rust toolchain via overlay
        _module.args.pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import inputs.rust-overlay) ];
        };
      };
    };
}
```

## Step 2: Packaging the Rust Application

Create `nix/package.nix` to build your Rust binary. We use `buildRustPackage` from the `rust-overlay`.

```nix
{ pkgs, rustPlatform, ... }:
rustPlatform.buildRustPackage {
  pname = "my-app";
  version = "0.1.0";
  src = ../.;
  cargoLock = { lockFile = ../Cargo.lock; };
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];
  # Optional: install assets like templates/static files
  postInstall = ''
    mkdir -p $out/share/app
    cp -r templates static $out/share/app/
  '';
}
```

## Step 3: Creating the NixOS Service Module

Create `nix/module.nix` to define how your service runs as a systemd unit. This is critical for containerization.

```nix
{ self }: { config, lib, pkgs, ... }:
let
  cfg = config.services.my-app;
in {
  options.services.my-app = {
    enable = lib.mkEnableOption "My Rust App";
    port = lib.mkOption { type = lib.types.port; default = 8000; };
    databaseUrl = lib.mkOption { type = lib.types.str; };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.my-app = {
      description = "My Rust Application";
      wantedBy = [ "multi-user.target" ];
      environment = {
        PORT = toString cfg.port;
        DATABASE_URL = cfg.databaseUrl;
      };
      serviceConfig = {
        ExecStart = "${self.packages.${pkgs.system}.default}/bin/my-app";
        Restart = "always";
      };
    };
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
```

## Step 4: Defining the Cluster Composition

Create `nix/composition.nix` to wire your nodes together using `nix-compose`.

```nix
{ pkgs, self, nix-compose }:
nix-compose.lib.mkCompose {
  name = "dev-cluster";
  nodes = {
    # The Application Node
    app = { ... }: {
      imports = [ self.nixosModules.default ];
      services.my-app = {
        enable = true;
        databaseUrl = "postgres://user:pass@db/dbname";
      };
    };
    # The Database Node
    db = { ... }: {
      services.postgresql = {
        enable = true;
        enableTCPIP = true;
        authentication = pkgs.lib.mkOverride 10 "host all all 0.0.0.0/0 trust";
      };
      networking.firewall.allowedTCPPorts = [ 5432 ];
    };
  };
  # Ensure DB starts before the App
  nodeConfig = {
    db = { order = 10; };
    app = { order = 20; };
  };
}
```

## Step 5: Final Wiring in `flake.nix`

Add the package, module, and composition to your `perSystem` outputs.

```nix
perSystem = { pkgs, system, ... }: 
let
  composition = import ./nix/composition.nix { inherit pkgs self nix-compose; };
in {
  packages.default = pkgs.callPackage ./nix/package.nix { };
  
  # Export the orchestration CLI
  apps.default = nix-compose.lib.mkApp { inherit pkgs composition; };
  
  # Export as a module for host-level management
  nixosModules.default = import ./nix/module.nix { inherit self; };
};
```

## Step 6: Running your Cluster

Now you can manage your multi-node environment with simple commands:

1.  **Start the cluster**:
    ```bash
    nix run . up
    ```
2.  **Access a node**:
    ```bash
    nix run . shell app
    ```
3.  **Check status**:
    ```bash
    nix run . status
    ```
4.  **Stop everything**:
    ```bash
    nix run . down
    ```

## Step 7: Declarative Host Integration (Optional)

Instead of manually running `nix run . up`, you can integrate the cluster directly into your NixOS host configuration. This makes the containers part of your system lifecycle (starting on boot) and provides the `nxc-<name>` command globally.

Add the following to your `flake.nix` outputs:

```nix
{
  outputs = { self, nixpkgs, nix-compose, ... }: {
    # Assuming self.compositions.default is your mkCompose result
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix # Your base host config
        self.compositions.default.nixosModule
        {
          # Enable the cluster on the host
          nxc.compose.dev-cluster = {
            enable = true;
            autoStart = true; # Start containers automatically on boot
          };
        }
      ];
    };
  };
}
```

After rebuilding your host (`nixos-rebuild switch`), the `nxc-dev-cluster` command will be available in your PATH, and the containers will be managed as standard NixOS containers.

### Why this is powerful:
- **Isolation**: Your database and app run in separate containers but talk to each other via internal DNS (the app connects to `db`).
- **Reproducibility**: The exact same setup works on any NixOS machine.
- **Speed**: `nix-compose` handles the networking, bridge creation, and IP allocation automatically.
