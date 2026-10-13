## Quick Start

This project automates the network bridging, storage provisioning, and Incus clustering layout for a Raspberry Pi 5 equipped with an NVMe drive. 

By leveraging a pre-configured **"Golden Image" MicroSD card** (pre-loaded with dependencies like `make`, `mise`, `rust`, etc.), you can completely bootstrap a new bare-metal cluster node using simple automated targets.

### Prerequisites

1. Flash your custom `ext4` base image onto a MicroSD card and boot the Raspberry Pi 5.
2. Insert your target NVMe drive into the Raspberry Pi 5 PCIe slot.
3. On your **Incus Cluster Leader** (e.g., `lenold`), generate a new cluster join token:
   ```bash
   incus cluster add <desired-new-node-hostname>
   ```
4. Paste this token into the `CLUSTER_JOIN_TOKEN` variable inside the `./incus-init.sh` script on the target Raspberry Pi 5.

### Installation

Clone this repository onto your active Raspberry Pi 5 session and navigate to the project directory. 

You can execute the entire deployment pipeline sequentially using a single command, or run the lifecycle targets one by one:

#### Option A: Full Automatic Deployment (Recommended)
To run the complete sequence (Network Bridge Setup ➔ NVMe Auto-Partitioning & OS Migration ➔ Hostname Configuration & Incus Join):
```bash
sudo make all NODE_NAME=rpi5-node3 DISK=/dev/nvme0n1
```
*(Replace `rpi5-node3` with your intended hostname and adjust `DISK` if your NVMe block device paths differ).*

#### Option B: Step-by-Step Deployment
If you prefer fine-grained control or need to debug specific pipeline phases, execute the individual `make` targets separately:

1. **Setup the Static Network Bridge (`br0`):**
   ```bash
   sudo make network
   ```
2. **Auto-Partition NVMe (Btrfs with zstd) and Migrate the OS:**
   ```bash
   sudo make imager DISK=/dev/nvme0n1
   ```
3. **Change Hostname and Securely Join the Active Incus Cluster:**
   ```bash
   sudo make incus NODE_NAME=rpi5-node3
   ```

### Next Steps

Once the scripts complete successfully, reboot your Raspberry Pi 5:
```bash
sudo reboot
```

The system will cleanly boot straight from your high-speed NVMe drive. The `br0` interface will initialize with zero STP delay, and the Incus daemon will immediately begin accepting cluster container/VM scheduling using the native Btrfs Copy-on-Write backend.

