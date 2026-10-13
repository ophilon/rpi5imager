# Using Incus with Btrfs Filesystem on Raspberry Pi 5

This document explains the storage architecture utilized in our automation project and outlines the benefits of running the **Btrfs** filesystem on **NVMe** drives for managing LXC containers and QEMU virtual machines via **Incus**.

---

## Storage Architecture

When deploying a cluster node or a standalone server, our `rpi5imager.sh` automation script performs the following actions:
1. Initializes the base system on a MicroSD card (ext4).
2. Formats the high-speed **NVMe drive with the Btrfs filesystem**.
3. Migrates the active system to the NVMe drive, creating a high-performance foundation for containers and virtual machines.

When you initialize Incus (`incus admin init`), it automatically detects that the underlying system runs on Btrfs and provisions a `btrfs` type storage pool. This unlocks native, kernel-level data management features.

---

## Key Benefits of Btrfs for LXC and QEMU inside Incus

### 1. Instant Cloning and Instance Creation (Copy-on-Write)
Btrfs operates on a **Copy-on-Write (CoW)** mechanism.
* **How it works:** When launching a new container from an image or cloning an existing virtual machine, Incus does not physically duplicate data blocks on the disk. Instead, it creates a subvolume clone that points to the pre-existing data blocks.
* **The Result:** Deploying a new LXC container or QEMU VM takes **less than 1 second**, regardless of the image size. Actual disk space is consumed only when files are modified or added inside the new instance.

### 2. Atomic and Lightweight Snapshots
You can take instant snapshots of your instances (`incus snapshot create`) before updating software or experimenting with configurations.
* On Btrfs, snapshot creation is **instantaneous** and introduces no I/O freezes or container latency, as it merely logs metadata inside the Linux kernel.
* Snapshots occupy zero additional space on your NVMe drive at the moment of creation. They grow only as the container generates new data and overwrites older blocks.

### 3. Transparent On-the-Fly Compression
Btrfs supports transparent filesystem-level compression (such as `zstd`).
* **Space Efficiency:** Operating system files inside containers (logs, binaries, libraries) compress highly efficiently. This allows you to fit 1.5× to 2.6× more isolated environments onto a single NVMe drive.
* **Enhanced Read Performance:** The Broadcom BCM2712 processor on the Raspberry Pi 5 features 4 powerful cores. It is faster for the CPU to read a compressed block from the NVMe and decompress it in RAM than to read a massive uncompressed file directly from the storage bus. This effectively reduces PCIe bus saturation.

### 4. Tailored Optimization for QEMU Virtual Machines
Unlike containers, virtual machines rely on heavy virtual disk images (`.img`/`.qcow2` files).
* On traditional filesystems (like ext4), cloning a 20–50 GB virtual machine forces long physical read/write duplication cycles, causing unnecessary wear on the NVMe flash cells.
* On Btrfs, Incus leverages the kernel's `reflink` command to duplicate only block pointers. For QEMU VMs, this ensures instant backups and rapid environment replication without disk degradation.

### 5. Highly Efficient Cluster Replication (Btrfs Send/Receive)
If you combine multiple Raspberry Pi 5 boards into an Incus cluster, Btrfs makes container migration between host servers incredibly fast.
* When moving an instance from one node to another, Incus utilizes native `btrfs send` and `btrfs receive` commands. Instead of scanning and sending millions of individual files over the network, it streams modified data blocks directly at the filesystem layer.

---

## Utilizing MicroSD (ext4) as a "Golden Image" for Node Replication

Our project architecture allows you to use a standard MicroSD card (`mmcblk0`) formatted in `ext4`—containing pre-configured system users, SSH keys, network utilities, and compilers (`mise`, `rust`, `build-essential`)—as a **template (Golden Image)** for scaling out your cluster.

### Benefits of this approach:
* **Homogeneous Cluster Nodes:** All new Raspberry Pi 5 units boot up with an identical set of pre-installed software, system accounts, and security profiles.
* **Rapid Disaster Recovery:** If a Raspberry Pi 5 board or its NVMe drive fails, you simply insert a duplicate of your "golden" MicroSD card into a replacement board, attach a new NVMe drive, run `rpi5imager.sh`, and rejoin the node to your cluster. Recovery takes less than 5 minutes.
* **Risk Isolation:** Any runtime issues or filesystem corruption inside your containers/VMs (such as critical disk space depletion) are contained within the NVMe storage pool and will not affect the bootable MicroSD card. The host operating system remains accessible via SSH for remote diagnostics and recovery.

---

## New Node Deployment Pipeline

When setting up a new Raspberry Pi 5 board using a pre-configured "Golden Image" MicroSD card, the provisioning and cluster joining process is streamlined as follows:

1. **Flash the Image:** Burn your custom `ext4` base image to the new node's MicroSD card.
2. **Configure the Network Bridge:** Run the network automation script:
   ```bash
   sudo ./nmcli-br0.sh
   ```
   *(The `br0` bridge initializes instantly with your defined static parameters, bypassing default STP delays).*
3. **Prepare the NVMe Drive:** Run your disk provisioning and system migration script:
   ```bash
   sudo ./rpi5imager.sh
   ```
   *(The NVMe base layer is now prepared with Btrfs).*
4. **Change Hostname and Join the Cluster:** Generate a join token on your cluster leader (`incus cluster add <name>`) and execute the initialization script using the `--name` flag. The script dynamically updates the system hostname via `hostnamectl` and registers the node in the Incus cluster under its new identity:
   ```bash
   sudo ./incus-init.sh --name rpi5-node3
   ```
   *If you wish to retain the pre-existing system hostname, simply run the script without arguments:* `sudo ./incus-init.sh`.

---

## Summary Comparison: Btrfs vs. Standard Directory (ext4)

| Feature | Directory Storage Pool (Standard ext4) | Btrfs Storage Pool (Our Project) |
| :--- | :--- | :--- |
| **Container Creation Speed** | Slow (requires physical extraction and file copying) | **Instant** (under a second via native CoW subvolumes) |
| **Snapshot Generation** | Slow file-by-file duplication | **Instant** (atomic metadata logging) |
| **Snapshot Storage Efficiency** | Consumes full file size (100% data duplication) | Consumes space **only for modified blocks** (delta) |
| **Transparent Disk Compression** | Not supported | **Supported (zstd)** — saves space and extends NVMe lifespan |
| **QEMU Disk Cloning** | Requires full file read/write operations | **Instant** via kernel-level `reflink` |

---

## Verifying Storage Status After Initialization

Once your network configuration and Incus initialization scripts finish successfully, verify that the storage pool is active by running:

```bash
incus storage list
```

You should see the `default` storage pool active with the `btrfs` driver:
```text
+---------+--------+-----------------------+-------------+---------+---------+

|  NAME   | DRIVER |        SOURCE         | DESCRIPTION | USED BY | STATE   |
+---------+--------+-----------------------+-------------+---------+---------+

| default | btrfs  | /var/lib/incus/sto... |             | 1       | CREATED |
+---------+--------+-----------------------+-------------+---------+---------+
```

To monitor space distribution and active compression statistics directly on the NVMe drive, use the system command:
```bash
sudo btrfs filesystem usage /
```

