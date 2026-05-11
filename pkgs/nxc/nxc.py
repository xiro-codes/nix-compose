#!/usr/bin/env python3
import sys
import json
import subprocess
import shutil
import argparse

# Configuration injected by Nix
CONNECT_INFO = json.loads('@connectInfoJSON@')
INTERNAL_IPS = json.loads('@internalIpsJSON@')
NODES = json.loads('@nodesJSON@')
ORDERED_NODES = json.loads('@orderedNodesJSON@')
CONTAINER_NAMES = json.loads('@containerNamesJSON@')
CLUSTER_NAME = "@clusterName@"
CLUSTER_HASH = "@clusterHash@"
BRIDGE_IP = "@bridgeIp@"
NIXOS_CONTAINER = "@nixosContainer@"
NIXPKGS_PATH = "@nixpkgsPath@"

def run(cmd, capture_output=False, check=True):
    """Helper to run shell commands with sudo if needed."""
    full_cmd = ["sudo"] + cmd
    result = subprocess.run(
        full_cmd, 
        capture_output=capture_output, 
        text=True, 
        check=False
    )
    if check and result.returncode != 0:
        if capture_output:
            print(result.stderr)
        sys.exit(result.returncode)
    return result

def check_ip_conflicts(bridge_name):
    """Verify bridge IP is not already in use by another interface."""
    # Use ip -4 addr show to find existing interfaces with this IP
    try:
        output = subprocess.check_output(["ip", "-4", "addr", "show"], text=True)
        for line in output.splitlines():
            if BRIDGE_IP in line:
                parts = line.split()
                if parts[-1] != bridge_name:
                    print(f"Error: Bridge IP {BRIDGE_IP} is already in use by interface {parts[-1]}")
                    print("Please use a different subnet for this composition.")
                    sys.exit(1)
    except subprocess.CalledProcessError:
        pass

def cmd_up():
    bridge_name = f"br-{CLUSTER_NAME[:12]}"
    print(f"Ensuring bridge {bridge_name} for cluster: {CLUSTER_NAME}")
    
    check_ip_conflicts(bridge_name)
    
    run(["ip", "link", "add", "name", bridge_name, "type", "bridge"], check=False)
    run(["ip", "link", "set", bridge_name, "up"])
    run(["ip", "addr", "add", f"{BRIDGE_IP}/24", "dev", bridge_name], check=False)
    run(["iptables", "-I", "INPUT", "-i", bridge_name, "-j", "ACCEPT"], check=False)
    run(["iptables", "-I", "FORWARD", "-i", bridge_name, "-j", "ACCEPT"], check=False)

    print(f"Cleaning up orphaned containers for cluster hash: {CLUSTER_HASH}")
    list_result = run([NIXOS_CONTAINER, "list"], capture_output=True)
    existing_containers = list_result.stdout.splitlines()
    
    valid_container_ids = set(CONTAINER_NAMES.values())
    for container in existing_containers:
        if container.endswith(f"-{CLUSTER_HASH}"):
            if container not in valid_container_ids:
                print(f"  - Destroying orphaned container: {container}")
                run([NIXOS_CONTAINER, "stop", container], check=False)
                run([NIXOS_CONTAINER, "destroy", container], check=False)

    print(f"Starting NixOS containers for cluster: {CLUSTER_NAME} ({CLUSTER_HASH})")
    # Ensure NIX_PATH is set for nixos-container
    import os
    os.environ["NIX_PATH"] = f"nixpkgs={NIXPKGS_PATH}:{os.environ.get('NIX_PATH', '')}"

    for node in ORDERED_NODES:
        toplevel = NODES[node]
        container_name = CONTAINER_NAMES[node]
        ip = INTERNAL_IPS[node]
        
        if container_name in existing_containers:
            print(f"  - Updating {node} ({container_name}) to {toplevel}...")
            run(["nix-env", "-p", f"/nix/var/nix/profiles/per-container/{container_name}/system", "--set", toplevel])
            
            status_result = run([NIXOS_CONTAINER, "status", container_name], capture_output=True)
            if status_result.stdout.strip() == "up":
                run([NIXOS_CONTAINER, "run", container_name, "--", "/nix/var/nix/profiles/system/bin/switch-to-configuration", "switch"])
        else:
            print(f"  - Creating {node} ({container_name}) at {ip}...")
            run([
                NIXOS_CONTAINER, "create", container_name,
                "--system-path", toplevel,
                "--bridge", bridge_name,
                "--local-address", ip,
                "--host-address", BRIDGE_IP
            ])
        
        run([NIXOS_CONTAINER, "start", container_name])
    
    print("Cluster is up. Use 'nxc status' to monitor.")

def cmd_down():
    print("Stopping and destroying NixOS containers...")
    for node in reversed(ORDERED_NODES):
        container_name = CONTAINER_NAMES[node]
        print(f"  - Stopping {container_name}...")
        run([NIXOS_CONTAINER, "stop", container_name], check=False)
        run([NIXOS_CONTAINER, "destroy", container_name], check=False)
    
    bridge_name = f"br-{CLUSTER_NAME[:12]}"
    print(f"Removing bridge {bridge_name}...")
    run(["iptables", "-D", "INPUT", "-i", bridge_name, "-j", "ACCEPT"], check=False)
    run(["iptables", "-D", "FORWARD", "-i", bridge_name, "-j", "ACCEPT"], check=False)
    run(["ip", "link", "delete", bridge_name], check=False)

def cmd_status():
    print(f"Cluster Status ({CLUSTER_NAME}):")
    print(f"{'NODE':<12} {'CONTAINER':<20} {'IP':<15} {'STATUS':<10}")
    print("-" * 72)
    for node in ORDERED_NODES:
        container_name = CONTAINER_NAMES[node]
        ip = INTERNAL_IPS[node]
        status_result = run([NIXOS_CONTAINER, "status", container_name], capture_output=True, check=False)
        status = status_result.stdout.strip() if status_result.returncode == 0 else "down"
        print(f"{node:<12} {container_name:<20} {ip:<15} {status:<10}")

def cmd_ssh(node, command_args=None):
    if node not in CONTAINER_NAMES:
        print(f"Error: Unknown node {node}")
        sys.exit(1)
    
    container_name = CONTAINER_NAMES[node]
    list_result = run([NIXOS_CONTAINER, "list"], capture_output=True)
    if container_name not in list_result.stdout.splitlines():
        print(f"Error: Container {container_name} is not running.")
        sys.exit(1)

    if command_args:
        print(f"Running command on {node}...")
        full_cmd = ["su", "-", "vmuser", "-c", " ".join(command_args)]
        run([NIXOS_CONTAINER, "run", container_name, "--"] + full_cmd)
    else:
        print(f"Connecting to {node} via machinectl shell...")
        subprocess.run(["sudo", "machinectl", "shell", f"vmuser@{container_name}"])

def cmd_logs(node):
    if node not in CONTAINER_NAMES:
        print(f"Error: Unknown node {node}")
        sys.exit(1)
    container_name = CONTAINER_NAMES[node]
    print(f"Showing live logs for {node} ({container_name})...")
    subprocess.run(["sudo", NIXOS_CONTAINER, "run", container_name, "--", "journalctl", "-f"])

def cmd_ip(node):
    ip = INTERNAL_IPS.get(node)
    if not ip:
        print(f"Error: Unknown node {node}", file=sys.stderr)
        sys.exit(1)
    print(ip)

def cmd_hosts():
    print(f"# Nix-Compose Hosts for {CLUSTER_NAME}")
    for node, ip in INTERNAL_IPS.items():
        print(f"{ip} {node}")

def main():
    parser = argparse.ArgumentParser(prog=f"nxc-{CLUSTER_NAME}", description="Nix-Compose CLI")
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    subparsers.add_parser("up", help="Start NixOS containers")
    subparsers.add_parser("down", help="Stop and destroy containers")
    
    ssh_parser = subparsers.add_parser("ssh", help="Enter a node container")
    ssh_parser.add_argument("node", help="Node name")
    ssh_parser.add_argument("args", nargs="*", help="Command to run")

    shell_parser = subparsers.add_parser("shell", help="Alias for ssh")
    shell_parser.add_argument("node", help="Node name")
    shell_parser.add_argument("args", nargs="*", help="Command to run")

    logs_parser = subparsers.add_parser("logs", help="Show live logs for a node")
    logs_parser.add_argument("node", help="Node name")

    subparsers.add_parser("status", help="Show the status of running containers")
    subparsers.add_parser("list", help="List all configured nodes")
    
    ip_parser = subparsers.add_parser("ip", help="Print internal IP of a node")
    ip_parser.add_argument("node", help="Node name")

    subparsers.add_parser("hosts", help="Print /etc/hosts content")

    args = parser.parse_args()

    if args.command == "up":
        cmd_up()
    elif args.command == "down":
        cmd_down()
    elif args.command in ["ssh", "shell"]:
        cmd_ssh(args.node, args.args)
    elif args.command == "logs":
        cmd_logs(args.node)
    elif args.command == "status":
        cmd_status()
    elif args.command == "list":
        print("Configured Nodes:")
        for node in ORDERED_NODES:
            print(f"  - {node}")
    elif args.command == "ip":
        cmd_ip(args.node)
    elif args.command == "hosts":
        cmd_hosts()
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
