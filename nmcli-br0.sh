#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# ==============================================================================
# CONFIGURATION VARIABLES (Adjust for each cluster node as needed)
# ==============================================================================
STATIC_IP="192.168.100.208/24"
GATEWAY="192.168.100.1"
DNS_SERVERS="192.168.100.201,192.168.100.1,86.57.253.204,8.8.8.8"
PHYS_INTERFACE="eth0"
BRIDGE_NAME="br0"
SLAVE_NAME="br0-eth0"

# ==============================================================================
# AUTOMATION LOGIC
# ==============================================================================

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo." >&2
  exit 1
fi

echo "=== 1. Dynamically finding active ethernet connection ==="
# Get the connection name currently tied to the physical interface
ORIG_CONN=$(nmcli -g NAME,DEVICE connection show --active | grep -E ":${PHYS_INTERFACE}$" | cut -d':' -f1 || true)

if [ -z "$ORIG_CONN" ]; then
  echo "Warning: No active connection found bound to ${PHYS_INTERFACE}."
  echo "Defaulting to fallback string 'Wired connection 1'."
  ORIG_CONN="Wired connection 1"
else
  echo "Found active connection to migrate: '${ORIG_CONN}'"
fi

echo "=== 2. Cleaning up any legacy configurations ==="
nmcli connection delete "$BRIDGE_NAME" 2>/dev/null || true
nmcli connection delete "$SLAVE_NAME" 2>/dev/null || true

echo "=== 3. Creating the br0 bridge connection ==="
nmcli connection add type bridge con-name "$BRIDGE_NAME" ifname "$BRIDGE_NAME"

echo "=== 4. Setting static network parameters ==="
nmcli connection modify "$BRIDGE_NAME" \
  ipv4.method manual \
  ipv4.addresses "$STATIC_IP" \
  ipv4.gateway "$GATEWAY" \
  ipv4.dns "$DNS_SERVERS" \
  bridge.stp no \
  connection.autoconnect yes

echo "=== 5. Attaching ${PHYS_INTERFACE} to the bridge ==="
nmcli connection add type bridge-slave con-name "$SLAVE_NAME" ifname "$PHYS_INTERFACE" master "$BRIDGE_NAME"
nmcli connection modify "$SLAVE_NAME" connection.autoconnect yes

echo "=== 6. Swapping connections (Activating bridge) ==="
# We use standard '|| true' on connection down so the script doesn't crash
# if the original default profile isn't active or named identically.
nmcli connection down "$ORIG_CONN" 2>/dev/null || true
nmcli connection up "$BRIDGE_NAME"

echo "=============================================================================="
echo " Bridge $BRIDGE_NAME successfully configured and activated! "
echo " Static IP: $STATIC_IP"
echo " STP: Disabled (Fast Boot-Up Enabled)"
echo "=============================================================================="
