set shell := ["bash", "-c"]

# Start the cluster
up:
    nix run . up

# Stop the cluster
down:
    nix run . down

# SSH into a node
ssh node:
    nix run . ssh -- {{node}}

# Show cluster status
status:
    nix run . status

# List all nodes
list:
    nix run . list

# Get IP of a node
ip node:
    nix run . ip -- {{node}}

# Build all container toplevels
build:
    @nodes=$$(nix run . list | sed 's/- //'); \
    for node in $$nodes; do \
        echo "Building $$node..."; \
        nix build .#$$node --no-link; \
    done
