# Pure Nix Compose

A lightweight, multi-node NixOS container orchestration library implemented in pure Nix. This project replicates the core features of `nixos-compose` (like inter-node networking, SSH key injection, and a unified CLI) using only built-in Nixpkgs infrastructure and `nixos-container`.

> [!CAUTION]
> **Use at your own risk.** This library is currently in an experimental state. It uses `systemd-nspawn` and `nixos-container` which require root privileges (`sudo`).

## Features

- **Pure Nix**: No external binaries or heavy dependencies required—just Nix.
- **Fast Startup**: Uses NixOS Containers (`nixos-container`) instead of QEMU VMs for near-instant boot times.
- **Unified CLI**: Emulates the `nixos-compose` experience (`up`, `down`, `ssh`, `status`, etc.) via a Flake app.
- **Automatic Networking**: Seamless node-to-node connectivity using internal container networks.

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
    compositions.x86_64-linux.default = nix-compose.lib.mkComposition {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      nodes = {
        server = { ... }: { services.nginx.enable = true; };
        client = { ... }: { /* ... */ };
      };
    };

    apps.x86_64-linux.default = nix-compose.lib.mkApp {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      composition = self.compositions.x86_64-linux.default;
      system = "x86_64-linux";
    };
  };
}
```

## Usage

Once set up, you can interact with your cluster using the following commands:

- `nix run . up` - Start the containers (requires `sudo`).
- `nix run . ssh <node>` - Enter a specific node's shell.
- `nix run . status` - Check if the containers are running.
- `nix run . list` - List all configured nodes.
- `nix run . down` - Stop and destroy the containers.

## License

MIT
