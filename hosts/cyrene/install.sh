#!/usr/bin/env nix-shell
#!nix-shell -i bash -p gptfdisk parted dosfstools nvme-cli sbctl git
# Cyrene ZFS-on-root installer — run as root from the NixOS live ISO.
# The nix-shell shebang above pulls in all required tools automatically;
# no manual `nix-shell -p ...` needed.
#
# Usage:
#   sudo ./install.sh <disk1-by-id> <disk2-by-id> [options]
#
# Example:
#   sudo ./install.sh \
#     /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_4TB_AAAA \
#     /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_4TB_BBBB \
#     --format-lba --install
#
# Options:
#   --format-lba   Reformat NVMe namespaces to 4K LBA first (ERASES DRIVES)
#   --no-wipe      Skip partitioning (reuse existing ESP/ZFS partitions)
#   --install      Run nixos-install at the end
#   --ssh-key FILE Copy an SSH public key into hosts/cyrene/authorized_keys
#
# The script ALWAYS destroys any existing rpool. It prompts once before
# touching anything.

set -euo pipefail

# ------------------------------------------------------------------ config
ESP_SIZE="32G"
SWAP_SIZE="64G"
HOSTID="69e5e3ea"                       # must match hosts/cyrene/zfs/boot.nix
REPO_URL="https://github.com/tyler274/nixos"
FLAKE_ATTR="CyreneMinimal"
POOL="rpool"

# ------------------------------------------------------------------ args
FORMAT_LBA=0
WIPE=1
RUN_INSTALL=0
SSH_KEY=""

DISK1="${1:?usage: $0 <disk1-by-id> <disk2-by-id> [--format-lba] [--no-wipe] [--install] [--ssh-key FILE]}"
DISK2="${2:?second disk required}"
shift 2

while [ $# -gt 0 ]; do
  case "$1" in
    --format-lba) FORMAT_LBA=1 ;;
    --no-wipe)    WIPE=0 ;;
    --install)    RUN_INSTALL=1 ;;
    --ssh-key)    SSH_KEY="${2:?--ssh-key needs a file}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# ------------------------------------------------------------------ checks
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -e "$DISK1" ] || { echo "no such disk: $DISK1" >&2; exit 1; }
[ -e "$DISK2" ] || { echo "no such disk: $DISK2" >&2; exit 1; }
case "$DISK1" in /dev/disk/by-id/*) ;; *) echo "use /dev/disk/by-id/ paths" >&2; exit 1 ;; esac
case "$DISK2" in /dev/disk/by-id/*) ;; *) echo "use /dev/disk/by-id/ paths" >&2; exit 1 ;; esac
[ -n "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ] && { echo "ssh key not found: $SSH_KEY" >&2; exit 1; }

for tool in sgdisk partprobe zpool zfs mkfs.vfat sbctl git; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool (run via the nix-shell shebang: sudo ./install.sh ..., or: nix-shell -p gptfdisk parted dosfstools nvme-cli sbctl git)" >&2; exit 1; }
done
if [ "$FORMAT_LBA" -eq 1 ]; then
  command -v nvme >/dev/null || { echo "missing tool: nvme (nix-shell -p nvme-cli)" >&2; exit 1; }
fi

echo "=== Cyrene ZFS install ==="
echo "  disk 1 : $DISK1"
echo "  disk 2 : $DISK2"
echo "  ESP    : $ESP_SIZE   swap zvol: $SWAP_SIZE"
echo "  wipe partitions: $WIPE   4K LBA format: $FORMAT_LBA   run install: $RUN_INSTALL"
echo
echo "!!! This DESTROYS any existing '$POOL' pool and (unless --no-wipe) ALL DATA on both disks."
read -r -p "Type YES to continue: " ans
[ "$ans" = "YES" ] || { echo "aborted"; exit 1; }

# ------------------------------------------------------------------ hostid
# On the live ISO /etc/hostid may be a symlink into the read-only /nix/store;
# zgenhostid writes through the symlink and fails with EROFS unless it's removed.
rm -f /etc/hostid
zgenhostid -f "$HOSTID"

# ------------------------------------------------------------------ teardown
echo "--- tearing down any existing state"
swapoff "/dev/zvol/$POOL/swap" 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
if zpool list "$POOL" >/dev/null 2>&1; then
  zpool destroy -f "$POOL"
elif zpool import 2>/dev/null | grep -q "pool: $POOL"; then
  zpool import -N -f "$POOL"
  zpool destroy -f "$POOL"
fi

# ------------------------------------------------------------------ 4K LBA
if [ "$FORMAT_LBA" -eq 1 ]; then
  echo "--- formatting NVMe namespaces to 4K LBA"
  for DISK in "$DISK1" "$DISK2"; do
    # Find an LBA format index with 4096-byte data size
    lbaf=$(nvme id-ns -H "$DISK" | awk '/LBA Format/ && /Data Size: 4096/ {gsub(/[^0-9]/,"",$3); print $3; exit}')
    if [ -n "$lbaf" ]; then
      echo "    $DISK -> lbaf=$lbaf"
      nvme format --lbaf="$lbaf" --force "$DISK"
    else
      echo "    $DISK has no 4096-byte LBA format, leaving as-is (ashift=12 still aligns correctly)"
    fi
  done
  sleep 2
fi

# ------------------------------------------------------------------ partition
if [ "$WIPE" -eq 1 ]; then
  echo "--- partitioning"
  for DISK in "$DISK1" "$DISK2"; do
    sgdisk --zap-all "$DISK"
    sgdisk -n1:1M:+"$ESP_SIZE" -t1:EF00 "$DISK"
    sgdisk -n2:0:0             -t2:BF00 "$DISK"
  done
  partprobe "$DISK1" "$DISK2"
  udevadm settle
fi
[ -e "${DISK1}-part2" ] || { echo "missing ${DISK1}-part2" >&2; exit 1; }
[ -e "${DISK2}-part2" ] || { echo "missing ${DISK2}-part2" >&2; exit 1; }

# ------------------------------------------------------------------ pool
echo "--- creating mirrored encrypted pool (you will be prompted for the passphrase)"
zpool create -f \
  -o ashift=12 \
  -o autotrim=on \
  -O encryption=on -O keyformat=passphrase -O keylocation=prompt \
  -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
  -O compression=zstd \
  -O normalization=formD \
  -O relatime=on \
  -O canmount=off -O mountpoint=none \
  -R /mnt \
  "$POOL" mirror "${DISK1}-part2" "${DISK2}-part2"
zpool status "$POOL"

# ------------------------------------------------------------------ datasets
echo "--- creating datasets"
zfs create -o canmount=off -o mountpoint=none  "$POOL/nixos"
zfs create -o canmount=off -o mountpoint=/var  "$POOL/nixos/var"
zfs create -o canmount=off -o mountpoint=/home "$POOL/nixos/home"

zfs create -o canmount=noauto -o mountpoint=/        "$POOL/nixos/root"
zfs create -o canmount=noauto -o mountpoint=/var/lib "$POOL/nixos/var/lib"
zfs create -o canmount=noauto -o mountpoint=/var/log "$POOL/nixos/var/log"

# legacy mountpoints are REQUIRED for these two (see zfs/filesystems.nix)
zfs create -o mountpoint=legacy -o com.sun:auto-snapshot=false -o sync=disabled "$POOL/nixos/tmp"
zfs create -o mountpoint=legacy -o com.sun:auto-snapshot=false "$POOL/docker"

# swap zvol — CyreneMinimal's swapDevices expects this
zfs create -V "$SWAP_SIZE" -b "$(getconf PAGESIZE)" \
  -o compression=zle -o logbias=throughput -o sync=always \
  -o primarycache=metadata -o com.sun:auto-snapshot=false \
  "$POOL/swap"
udevadm settle
mkswap -f "/dev/zvol/$POOL/swap"

# ------------------------------------------------------------------ mounts
echo "--- mounting under /mnt"
mount -t zfs -o zfsutil "$POOL/nixos/root" /mnt
mkdir -p /mnt/var/lib /mnt/var/log /mnt/tmp /mnt/boot
mount -t zfs -o zfsutil "$POOL/nixos/var/lib" /mnt/var/lib
mount -t zfs -o zfsutil "$POOL/nixos/var/log" /mnt/var/log
mount -t zfs "$POOL/nixos/tmp" /mnt/tmp
chmod 1777 /mnt/tmp

echo "--- ESPs"
mkfs.vfat -F32 -n EFI  "${DISK1}-part1"
mkfs.vfat -F32 -n EFI2 "${DISK2}-part1"   # spare on the second mirror leg
mount -o umask=0077 "${DISK1}-part1" /mnt/boot

# ------------------------------------------------------------------ repo
echo "--- cloning config repo"
rm -rf /mnt/root/nixos
git clone "$REPO_URL" /mnt/root/nixos

# Patch the ESP PARTUUID in hardware-configuration.nix to DISK1-part1
part1_name=$(basename "$(readlink -f "${DISK1}-part1")")
partuuid=$(lsblk -no PARTUUID "/dev/$part1_name")
[ -n "$partuuid" ] || { echo "could not determine PARTUUID of ${DISK1}-part1" >&2; exit 1; }
echo "    ESP PARTUUID: $partuuid"
sed -i -E "s|/dev/disk/by-partuuid/[0-9a-fA-F-]+|/dev/disk/by-partuuid/$partuuid|" \
  /mnt/root/nixos/hosts/cyrene/hardware-configuration.nix
grep -n "by-partuuid" /mnt/root/nixos/hosts/cyrene/hardware-configuration.nix

if [ -n "$SSH_KEY" ]; then
  cp "$SSH_KEY" /mnt/root/nixos/hosts/cyrene/authorized_keys
  echo "    installed authorized_keys from $SSH_KEY"
fi

# ------------------------------------------------------------------ secure boot
echo "--- Secure Boot PKI (lanzaboote expects /etc/secureboot)"
sbctl create-keys || true
mkdir -p /mnt/etc/secureboot
if [ -d /var/lib/sbctl ]; then
  cp -r /var/lib/sbctl/. /mnt/etc/secureboot/
elif [ -d /usr/share/secureboot ]; then
  cp -r /usr/share/secureboot/. /mnt/etc/secureboot/
else
  echo "WARNING: sbctl key dir not found; create keys manually before install" >&2
fi

# ------------------------------------------------------------------ install
if [ "$RUN_INSTALL" -eq 1 ]; then
  echo "--- running nixos-install (#$FLAKE_ATTR)"
  nixos-install --flake "/mnt/root/nixos#$FLAKE_ATTR" --no-root-passwd
  echo
  echo "=== done — reboot when ready. Root password comes from initialHashedPassword;"
  echo "=== you'll be prompted for the rpool passphrase at boot."
else
  echo
  echo "=== setup complete. Review /mnt/root/nixos, then run:"
  echo "    nixos-install --flake /mnt/root/nixos#$FLAKE_ATTR --no-root-passwd"
fi
