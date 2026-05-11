COMMAND="${1:-help}"
[ "$#" -gt 0 ] && shift

CONNECT_INFO='@connectInfoJSON@'
INTERNAL_IPS='@internalIpsJSON@'
NODES='@nodesJSON@'
ORDERED_NODES='@orderedNodesJSON@'
CONTAINER_NAMES='@containerNamesJSON@'
CLUSTER_NAME="@clusterName@"
CLUSTER_HASH="@clusterHash@"
NIXOS_CONTAINER="@nixosContainer@"

# Ensure nixos-container can find nixpkgs/nixos during creation/update
export NIX_PATH="nixpkgs=@nixpkgsPath@:${NIX_PATH:-}"

case "$COMMAND" in
  up)
    BRIDGE_NAME="br-${CLUSTER_NAME:0:12}"
    echo "Ensuring bridge $BRIDGE_NAME for cluster: $CLUSTER_NAME"
    sudo ip link add name "$BRIDGE_NAME" type bridge 2>/dev/null || true
    sudo ip link set "$BRIDGE_NAME" up
    sudo ip addr add 10.233.1.254/24 dev "$BRIDGE_NAME" 2>/dev/null || true
    sudo iptables -I INPUT -i "$BRIDGE_NAME" -j ACCEPT 2>/dev/null || true
    sudo iptables -I FORWARD -i "$BRIDGE_NAME" -j ACCEPT 2>/dev/null || true

    echo "Cleaning up orphaned containers for cluster hash: $CLUSTER_HASH"
    sudo "$NIXOS_CONTAINER" list < /dev/null | grep "\-$CLUSTER_HASH$" | while read -r C; do
      if ! echo "$CONTAINER_NAMES" | jq -e ".[] | select(. == \"$C\")" >/dev/null; then
        echo "  - Destroying orphaned container: $C"
        sudo "$NIXOS_CONTAINER" stop "$C" < /dev/null || true
        sudo "$NIXOS_CONTAINER" destroy "$C" < /dev/null || true
      fi
    done

    echo "Starting NixOS containers for cluster: $CLUSTER_NAME ($CLUSTER_HASH)"
    echo "$ORDERED_NODES" | jq -r '.[]' | while read -r NODE; do
      TOPLEVEL=$(echo "$NODES" | jq -r ".\"$NODE\"")
      CONTAINER_NAME=$(echo "$CONTAINER_NAMES" | jq -r ".\"$NODE\"")
      IP=$(echo "$INTERNAL_IPS" | jq -r ".\"$NODE\"")
      
      if sudo "$NIXOS_CONTAINER" list < /dev/null | grep -q "^$CONTAINER_NAME$"; then
        echo "  - Updating $NODE ($CONTAINER_NAME) to $TOPLEVEL..."
        # Update the system profile for the container
        sudo nix-env -p "/nix/var/nix/profiles/per-container/$CONTAINER_NAME/system" --set "$TOPLEVEL"
        # If running, trigger a switch-to-configuration
        if [ "$(sudo "$NIXOS_CONTAINER" status "$CONTAINER_NAME" < /dev/null)" = "up" ]; then
           sudo "$NIXOS_CONTAINER" run "$CONTAINER_NAME" -- /nix/var/nix/profiles/system/bin/switch-to-configuration switch
        fi
      else
        echo "  - Creating $NODE ($CONTAINER_NAME) at $IP..."
        # We pass both local and host addresses to ensure proper veth configuration
        sudo "$NIXOS_CONTAINER" create "$CONTAINER_NAME" \
          --system-path "$TOPLEVEL" \
          --bridge "$BRIDGE_NAME" \
          --local-address "$IP" \
          --host-address "10.233.1.254" < /dev/null
      fi
      sudo "$NIXOS_CONTAINER" start "$CONTAINER_NAME" < /dev/null
    done
    echo "Cluster is up. Use 'nxc status' to monitor."
    ;;
  down)
    echo "Stopping and destroying NixOS containers..."
    # Process nodes in reverse order for shutdown
    echo "$ORDERED_NODES" | jq -r 'reverse | .[]' | while read -r NODE; do
      CONTAINER_NAME=$(echo "$CONTAINER_NAMES" | jq -r ".\"$NODE\"")
      echo "  - Stopping $CONTAINER_NAME..."
      sudo "$NIXOS_CONTAINER" stop "$CONTAINER_NAME" < /dev/null || true
      sudo "$NIXOS_CONTAINER" destroy "$CONTAINER_NAME" < /dev/null || true
    done
    BRIDGE_NAME="br-${CLUSTER_NAME:0:12}"
    echo "Removing bridge $BRIDGE_NAME..."
    sudo iptables -D INPUT -i "$BRIDGE_NAME" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i "$BRIDGE_NAME" -j ACCEPT 2>/dev/null || true
    sudo ip link delete "$BRIDGE_NAME" 2>/dev/null || true
    ;;
  ssh|shell)
    NODE="${1:-}"
    if [ -z "$NODE" ]; then
      echo "Usage: nxc $COMMAND <node-name> [command...]"
      exit 1
    fi
    shift
    CONTAINER_NAME=$(echo "$CONTAINER_NAMES" | jq -r ".\"$NODE\" // empty")
    
    if [ -z "$CONTAINER_NAME" ]; then
      echo "Error: Unknown node $NODE"
      exit 1
    fi
    
    if ! sudo "$NIXOS_CONTAINER" list < /dev/null | grep -q "^$CONTAINER_NAME$"; then
      echo "Error: Container $CONTAINER_NAME is not running."
      exit 1
    fi

    if [ "$#" -gt 0 ]; then
      echo "Running command on $NODE..."
      sudo "$NIXOS_CONTAINER" run "$CONTAINER_NAME" -- su - vmuser -c "$*"
    else
      echo "Connecting to $NODE via machinectl shell..."
      # machinectl shell provides a proper TTY and environment
      sudo machinectl shell "vmuser@$CONTAINER_NAME"
    fi
    ;;
  list)
    echo "Configured Nodes:"
    echo "$CONNECT_INFO" | jq -r 'keys[]' | sed 's/^/- /'
    ;;
  ip)
    NODE="${1:-}"
    if [ -z "$NODE" ]; then
      echo "Usage: nxc ip <node-name>"
      exit 1
    fi
    IP=$(echo "$INTERNAL_IPS" | jq -r ".\"${NODE}\" // empty")
    if [ -z "$IP" ]; then
      echo "Error: Unknown node ${NODE}"
      exit 1
    fi
    echo "$IP"
    ;;
  hosts)
    echo "# Nix-Compose Hosts for $CLUSTER_NAME"
    echo "$INTERNAL_IPS" | jq -r 'to_entries[] | "\(.value) \(.key)"'
    ;;
  logs)
    NODE="${1:-}"
    if [ -z "$NODE" ]; then
      echo "Usage: nxc logs <node-name>"
      exit 1
    fi
    CONTAINER_NAME=$(echo "$CONTAINER_NAMES" | jq -r ".\"$NODE\" // empty")
    if [ -z "$CONTAINER_NAME" ]; then
      echo "Error: Unknown node $NODE"
      exit 1
    fi
    echo "Showing live logs for $NODE ($CONTAINER_NAME)..."
    sudo "$NIXOS_CONTAINER" run "$CONTAINER_NAME" -- journalctl -f
    ;;
  status)
    echo "Cluster Status ($CLUSTER_NAME):"
    printf "%-12s %-20s %-15s %-10s\n" "NODE" "CONTAINER" "IP" "STATUS"
    echo "------------------------------------------------------------------------"
    echo "$INTERNAL_IPS" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r NODE IP; do
      CONTAINER_NAME=$(echo "$CONTAINER_NAMES" | jq -r ".\"$NODE\"")
      # We use a subshell to avoid sudo prompts hanging if possible, though status is usually fine
      STATUS=$(sudo "$NIXOS_CONTAINER" status "$CONTAINER_NAME" 2>/dev/null || echo "down")
      printf "%-12s %-20s %-15s %-10s\n" "$NODE" "$CONTAINER_NAME" "$IP" "$STATUS"
    done
    ;;
  help|--help|-h)
    echo "Usage: nxc [COMMAND]"
    echo ""
    echo "Available commands:"
    echo "  up                       Start NixOS containers"
    echo "  down                     Stop and destroy containers"
    echo "  ssh <node>               Enter a node container"
    echo "  shell <node>             Alias for ssh"
    echo "  logs <node>              Show live logs for a node"
    echo "  status                   Show the status of running containers"
    echo "  list                     List all configured nodes"
    echo "  ip <node>                Print the internal ip address of a node"
    echo "  hosts                    Print the /etc/hosts content for the cluster"
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Run 'nxc help' for usage."
    exit 1
    ;;
esac
