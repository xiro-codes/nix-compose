# Pure Nix Compose

A lightweight, multi-node NixOS container orchestration library implemented in pure Nix. This project replicates the core features of `nixos-compose` (like inter-node networking, SSH key injection, and a unified CLI) using only built-in Nixpkgs infrastructure and `nixos-container`.

Now powered by a **Python-based orchestrator** for improved reliability and advanced features.

## Features

- **Pure Nix**: No external binaries or heavy dependencies required—just Nix.
- **Python CLI**: A robust, JSON-aware orchestrator for cluster lifecycle management.
- **Startup Ordering**: Define explicit startup/shutdown sequences for your nodes.
- **Dynamic Networking**: Automatic IP allocation with subnet support and conflict detection.
- **Flake Integration**: Seamlessly manage containers via Flake apps or native NixOS modules.
- **Automatic GC**: Prevents interface leaks by automatically cleaning up orphaned containers.

## Getting Started

### 1. Initialize from Template (Recommended)

The easiest way to start a new project is by using the provided template:

```bash
mkdir my-cluster && cd my-cluster
nix flake init -t github:xiro-codes/nix-compose
```

### 2. Manual Integration

Add `nix-compose` to your `flake.nix` inputs:

```nix
{
  inputs.nix-compose.url = "github:xiro-codes/nix-compose";

  outputs = { self, nixpkgs, nix-compose, ... }: {
    # 1. Define your composition (system-agnostic)
    compositions.default = nix-compose.lib.mkCompose {
      name = "my-cluster";
      subnet = "10.250.0"; # Optional: defaults to 10.233.1
      nodes = {
        server = { ... }: { services.nginx.enable = true; };
        db = { ... }: { services.postgresql.enable = true; };
      };
      nodeConfig = {
        db = { order = 10; }; # Start DB first
        server = { order = 20; };
      };
    };

    # 2. Export the CLI app for your system
    apps.x86_64-linux.default = nix-compose.lib.mkApp {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      composition = self.compositions.default;
    };
  };
}
```

## NixOS Module Integration

You can also manage your clusters declaratively as part of your host system configuration:

```nix
{
  # In your host NixOS configuration
  imports = [ self.compositions.nixosModule.default ];
  
  nxc.compose.my-cluster = {
    enable = true;
    autoStart = true; # Start containers on host boot
  };
}
```
*Enabling the module automatically adds the `nxc-my-cluster` CLI tool to your system PATH.*

## Usage

Interact with your cluster using the following commands (assuming `nix run .` or the installed system tool):

- `up` - Start the containers (requires `sudo`).
- `shell <node>` - Enter a specific node's shell.
- `status` - Check if the containers are running.
- `list` - List all configured nodes and their IPs.
- `down` - Stop and destroy the containers.

## License

MIT
