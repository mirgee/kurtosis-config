# Snap/2 Interop Testing

Kurtosis configs for testing snap/2 (the new Ethereum state sync protocol)
between client pairs. Each pair consists of a **source** node that serves
snap/2 data and a **sink** node that syncs from it.

Currently covers the four combinations:

| Source \ Sink | geth                       | besu                       |
|---------------|----------------------------|----------------------------|
| **geth**      | `source_geth` + `sink_geth`  | `source_geth` + `sink_besu`  |
| **besu**      | `source_besu` + `sink_geth`  | `source_besu` + `sink_besu`  |

All configs use **Lodestar** as the consensus client and run on the
**Glamsterdam devnet** schedule (Fulu at genesis, Gloas/Amsterdam at epoch 1).

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Kurtosis](https://docs.kurtosis.com/install/)

## Configs

### Source enclaves

The source runs a full node (validator + EL + CL) and produces state via
spamoor. Two variants:

| File | EL | Notes |
|------|----|-------|
| `network_params_source_geth.yaml` | geth | `--snap.v2` enabled, tx_fuzz + spamoor |
| `network_params_source_besu.yaml` | besu | `--Xsnap2-enabled`, spamoor (no tx_fuzz — legacy tx encoding not yet fixed) |

Both publish EL and CL ports on the host via `nat_exit_ip` for cross-enclave
peering.

### Sink enclaves

The sink runs a full node that joins the source's network and snap-syncs
from it. Two variants:

| File | EL | Notes |
|------|----|-------|
| `network_params_sink_geth.yaml` | geth | `--syncmode=snap --snap.v2` |
| `network_params_sink_besu.yaml` | besu | `--Xsnap2-enabled --sync-min-peers=1` |

Sinks use `--network.connectToDiscv5Bootnodes=false` and a hardcoded
`--directPeers` pointing at the source CL, because the two enclaves are on
separate Docker networks.

### Helper scripts

| Script | Purpose |
|--------|---------|
| `update-direct-peer-geth.sh` | Queries the source CL's REST API and writes its TCP multiaddr into `network_params_sink_geth.yaml` |
| `update-direct-peer-besu.sh` | Same, but targets `network_params_sink_besu.yaml` |

Must be run **after** the source enclave is up and **before** starting the
sink.

## Usage

### 1. Start the source

Pick the source EL (geth or besu) and start the enclave:

```bash
ETHEREUM_PACKAGE_COMMIT=a8c7cd6cc02c8c843563aa15a9ddcc128d22b51a

kurtosis run github.com/ethpandaops/ethereum-package@${ETHEREUM_PACKAGE_COMMIT} \
  --enclave source-enclave \
  --args-file network_params_source_geth.yaml \
  --image-download always
```

### 2. Wait for the chain to advance

Let the source produce blocks past the Amsterdam fork boundary
(epoch 1 = 32 blocks = 64 seconds):

```bash
# Check the source CL head slot
curl -sf http://127.0.0.1:33001/eth/v1/node/syncing | jq -r .data.head_slot
```

### 3. Update the sink's direct peer

Run the script that matches your sink EL:

```bash
# For a geth sink:
./update-direct-peer-geth.sh

# For a besu sink:
./update-direct-peer-besu.sh
```

This fetches the source CL's peer address from its REST API (port `33001`)
and writes it into the sink config's `--directPeers` line.

### 4. Start the sink

```bash
ETHEREUM_PACKAGE_COMMIT=a8c7cd6cc02c8c843563aa15a9ddcc128d22b51a

kurtosis run github.com/ethpandaops/ethereum-package@${ETHEREUM_PACKAGE_COMMIT} \
  --enclave sink-enclave \
  --args-file network_params_sink_geth.yaml \
  --image-download always
```

### 5. Monitor

```bash
# Geth sink logs
docker logs -f $(docker ps -q --filter "name=el-1-geth-lodestar" | tail -1)

# Besu sink logs
docker logs -f $(docker ps -q --filter "name=el-1-besu-lodestar" | tail -1)

# Sink sync progress (CL REST API)
curl -sf http://127.0.0.1:33101/eth/v1/node/syncing | jq
```

### 6. Tear down

```bash
kurtosis enclave rm -f sink-enclave
kurtosis enclave rm -f source-enclave
```

## Port layout

Both source and sink use `nat_exit_ip` to publish ports on the host. Adjust
`nat_exit_ip` in all configs to match your machine's LAN IP.

| Service | Source port | Sink port |
|---------|-------------|-----------|
| EL RPC        | 32003 | 32103 |
| EL engine     | 32001 | 32101 |
| EL p2p (tcp)  | 32000 | 32100 |
| EL p2p (udp)  | 32000 | 32100 |
| EL ws         | 32004 | 32104 |
| CL REST       | 33001 | 33101 |
| CL p2p (tcp)  | 33000 | 33100 |
| CL p2p (udp)  | 33000 | 33100 |
| nginx (net config) | 9090 | — |

## Fork schedule

| Fork   | Epoch | Activation |
|--------|-------|------------|
| Fulu   | 0     | Genesis    |
| Gloas  | 1     | Slot 32    |

With `seconds_per_slot: 2`, the Amsterdam (Gloas) fork activates ~64 seconds
after genesis (plus the 20s `genesis_delay`).

## State generation

Both source configs run [spamoor](https://github.com/ethpandaops/spamoor) with
a custom image (`mirgee/spamoor:erc20-bloater-amsterdam`) that generates
heavy state via:

- **erc20_bloater**: deploys ERC20 contracts with many storage slots per tx
- **storagespam**: raw storage writes
- **factorydeploytx**: contract deployments
- **erc20tx**: token transfers

The bloater is patched to use `eth_estimateGas` and
`MaxBloatedAddressesPerTx=70` (down from 370) to survive Amsterdam's
~5x state-gas costs (EIP-8037: 64x1530 = 97,920 gas per new storage slot).

Adjust `target_storage_gb` in the source config to control state size.

## Adding a new client

To test a client pair not yet covered:

1. **Source**: Copy `network_params_source_geth.yaml` (or besu), change
   `el_type`/`el_image`, and add any snap/2 server flags your client needs.

2. **Sink**: Copy `network_params_sink_geth.yaml` (or besu), change
   `el_type`/`el_image`, and add the snap/2 client flags.

3. **Peer script**: If your sink EL differs from geth/besu, copy
   `update-direct-peer-geth.sh` and change the `SINK_CONFIG` path.

4. **Ports**: Keep the sink's `public_port_start` at `32100`/`33100` to avoid
   collisions with the source.
