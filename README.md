# Pure Nix Compose

A lightweight, multi-node NixOS VM orchestration library implemented in pure Nix. This project replicates the core features of `nixos-compose` (like inter-node networking, SSH key injection, and a unified CLI) using only built-in Nixpkgs infrastructure (`nixosTest`).

> [!CAUTION]
> **Use at your own risk.** This library is currently in an experimental state. It involves complex QEMU orchestration and low-level NixOS configurations. Always back up your data before running local VM clusters.

## Features

- **Pure Nix**: No external binaries or heavy dependencies required—just Nix.
- **Unified CLI**: Emulates the `nixos-compose` experience (`up`, `down`, `ssh`, `status`, etc.) via a Flake app.
- **Automatic SSH**: Seamless node-to-node and host-to-node connectivity with pre-injected development keys.
- **Flexible Networking**: Uses the standard NixOS test framework for robust inter-node communication.

## Getting Started

### 1. Initialize from Template (Recommended)

The easiest way to start a new project is by using the provided template:

```bash
mkdir my-cluster && cd my-cluster
nix flake init -t github:tod/nix-compose
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

- `nix run . up` - Start the cluster in interactive mode.
- `nix run . ssh <node>` - SSH into a specific node.
- `nix run . status` - Check if the VMs are running.
- `nix run . list` - List all configured nodes.
- `nix run . down` - Stop the running cluster.

## License

MIT (See [LICENSE](LICENSE) if available)
