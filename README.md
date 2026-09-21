# rpi5imager

raspberry 5 shell script imager - copy rpi os setup from ssd to nvme drive
big diff to official imager - format nvme drive in btrfs and use fedora-like partition - subvolumes @root, @home, @var