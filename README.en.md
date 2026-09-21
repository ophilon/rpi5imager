A complete step-by-step guide on manually partitioning an NVMe drive, creating a Fedora-style Btrfs structure, transferring a clean OS, and configuring the Raspberry Pi 5 bootloader.
------------------------------

## Quick Start (Script)

Steps 2–9 of the guide below are automated in the `rpi5imager.sh` script.
Only the disk partitioning (Step 1) is performed manually. 

1. Partition the NVMe drive manually (see Step 1 below). 
2. Run the script as root:

sudo ./rpi5imager.sh

If necessary, specify a different drive using an environment variable:

DISK=/dev/nvme1n1 sudo ./rpi5imager.sh

The script will automatically create filesystems and subvolumes, transfer the OS,
insert the PARTUUID into fstab and cmdline.txt, generate the initramfs, and unmount the partitions.

------------------------------
## Step 1. Partitioning the NVMe Drive
For the Raspberry Pi 5, we need two partitions on the NVMe drive:

1. Bootloader partition (/boot/firmware): FAT32 type, 512 MB size. 
2. System and data partition: Btrfs type, occupying all remaining space.

Identify your NVMe drive name (usually /dev/nvme0n1). Open the partitioning utility:

sudo fdisk /dev/nvme0n1

Command sequence within fdisk:

1. Press g — create a new GPT partition table. 
2. Press n, then Enter, Enter, and type +512M — create the first partition. 
3. Press t, then 1 (type EFI System or FAT32). 
4. Press n, then Enter, Enter, Enter — create the second partition using the rest of the disk. 
5. Press w — save changes and exit. ------------------------------
## Step 2. Creating file systems

1. Format the boot partition as FAT32:

sudo mkfs.vfat -F 32 -n "boot" /dev/nvme0n1p1

2. Format the main partition as Btrfs:

sudo mkfs.btrfs -L "Debian" -f /dev/nvme0n1p2


------------------------------
## Step 3. Creating the subvolume structure (Fedora scheme)
Mount the clean Btrfs partition and create isolated subvolumes within it:

sudo mount /dev/nvme0n1p2 /mnt
sudo btrfs subvolume create /mnt/root
sudo btrfs subvolume create /mnt/home
sudo btrfs subvolume create /mnt/var

After creating the subvolumes, unmount the disk:

sudo umount /mnt

------------------------------
## Step 4. Preparing the mount tree for copying the OS
Now, mount the subvolumes to match the layout required for the running system so that the files can be transferred correctly. # 1. Mount the main root
sudo mount -o subvol=root,noatime /dev/nvme0n1p2 /mnt
# 2. Create mount points inside the new root
sudo mkdir -p /mnt/home /mnt/var /mnt/boot/firmware
# 3. Mount the remaining subvolumes to these points
sudo mount -o subvol=home,noatime /dev/nvme0n1p2 /mnt/home
sudo mount -o subvol=var,noatime /dev/nvme0n1p2 /mnt/var
# 4. Mount the future Raspberry Pi bootloader partition
sudo mount /dev/nvme0n1p1 /mnt/boot/firmware

------------------------------
## Step 5. Transferring the operating system from SSD to NVMe
Copy the entire currently running system from the SSD to the prepared NVMe drive. The -x (--one-file-system) flag is critical: it ensures rsync copies the OS itself but ignores virtual directories (/proc, /sys, /dev) and avoids an infinite loop caused by attempting to copy the NVMe drive into itself.

sudo rsync -axHAWXS --numeric-ids --info=progress2 / /mnt/

You also need to copy the firmware and bootloader files to the first partition. On the Raspberry Pi, these are located in /boot/firmware:

sudo rsync -axHAWXS --numeric-ids --info=progress2 /boot/firmware/ /mnt/boot/firmware/

------------------------------
## Step 6. Obtaining partition UUIDs
To configure the system files, we need the unique partition identifiers (PARTUUID). Retrieve them using the following command:

blkid | grep nvme0n1

The output will look something like this:

/dev/nvme0n1p1: PARTUUID="aaaa-01" TYPE="vfat"
/dev/nvme0n1p2: PARTUUID="aaaa-02" TYPE="btrfs"

Make a note of your `aaaa-01` and `aaaa-02` values.
------------------------------
## Step 7. Configuring files on the NVMe ## 1. Edit the new drive's `/etc/fstab`:

sudo nano /mnt/etc/fstab

Clear the existing content and set the file up as follows (substituting your own PARTUUIDs):

# Raspberry Pi 5 bootloader partition
PARTUUID=aaaa-01  /boot/firmware  vfat    defaults          0       2

# Root filesystem (including /usr)
PARTUUID=aaaa-02  /               btrfs   defaults,subvol=root,noatime  0  1

# User data and logs
PARTUUID=aaaa-02  /home           btrfs   defaults,subvol=home,noatime  0  2
PARTUUID=aaaa-02  /var            btrfs   defaults,subvol=var,noatime   0  2

## 2. Edit kernel boot parameters in `cmdline.txt`:

sudo nano /mnt/boot/firmware/cmdline.txt

Delete the entire contents of the line and paste the following configuration, ensuring it remains strictly on a single line with no line breaks:

console=serial0,115200 console=tty1 root=PARTUUID=aaaa-02 rootfstype=btrfs rootflags=subvol=root rw rootwait

(Here, `aaaa-02` is the PARTUUID of the second—Btrfs—partition).
------------------------------
## Step 8. Generating initramfs via Chroot
To allow the Raspberry Pi 5 kernel to read the Btrfs filesystem on the NVMe drive during startup, we need to build a full initial RAM disk (initrd) image within the new environment.
1. Bind-mount the current SSD's virtual file systems to the NVMe drive:

sudo mount --bind /dev /mnt/dev
sudo mount --bind /sys /mnt/sys
sudo mount --bind /proc /mnt/proc

2. Enter the NVMe drive's environment:

sudo chroot /mnt

3. Enable the inclusion of all necessary modules in initramfs. Open the file:

nano /etc/initramfs-tools/initramfs.conf

Ensure the modules line reads: MODULES=most
4. Generate a new kernel boot image (the command will automatically use the current version):

update-initramfs -c -k $(uname -r)

5. Verify that the created file (e.g., initrd.img-6.x.x-v8+) appears in the /boot/firmware/ folder. If it is missing, copy it there manually:

cp /boot/initrd.img-* /boot/firmware/

6. Ensure the Raspberry Pi configuration file is set to load this image. Open the file:

nano /boot/firmware/config.txt

At the very end of the file, there must be an active line specifying the exact name of your file (or a generic parameter for RPi):

initramfs initrd.img-6.6.31+v8 followkernel

(Replace initrd.img-6.6.31+v8 with the exact filename generated in /boot/firmware/). 
7. Exit the isolated environment:

exit


------------------------------
## Step 9. Completion and Reboot
Unmount all partitions to flush the write cache to the NVMe drive:

sudo umount -R /mnt
