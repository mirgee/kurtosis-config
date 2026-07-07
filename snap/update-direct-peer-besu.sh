#!/usr/bin/env bash
set -euo pipefail

SOURCE_REST_PORT=33001
SINK_CONFIG="$(dirname "$0")/network_params_sink_besu.yaml"

# Fetch the source CL's TCP multiaddr from its REST API
multiaddr=$(curl -sf "http://127.0.0.1:${SOURCE_REST_PORT}/eth/v1/node/identity" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
addrs = data['data']['p2p_addresses']
# Find the TCP multiaddr matching the nat_exit_ip (contains a dotted IPv4 and /tcp/)
for a in addrs:
    if '/tcp/' in a and '/p2p/' in a:
        # Skip loopback and private container IPs (172.x, 127.x, ::1)
        parts = a.split('/')
        ip = parts[2] if len(parts) > 2 else ''
        if not ip.startswith('172.') and not ip.startswith('127.') and ':' not in ip:
            print(a)
            break
")

if [ -z "$multiaddr" ]; then
  echo "ERROR: Could not fetch multiaddr from source CL at port ${SOURCE_REST_PORT}" >&2
  echo "Is the source enclave running?" >&2
  exit 1
fi

echo "Source multiaddr: $multiaddr"

# Update the --directPeers line in the sink config
sed -i "s|--directPeers=.*|--directPeers=${multiaddr}|" "$SINK_CONFIG"

echo "Updated $(basename "$SINK_CONFIG") with new --directPeers value"
