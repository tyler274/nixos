#!/usr/bin/env bash
# Cyrene rescue/maintenance helper — run as root from the NixOS live ISO.
# Imports the encrypted rpool and mounts the full hierarchy under /mnt,
# without touching or destroying anything. Counterpart to install.sh.
#
# Usage:
#   sudo ./rescue.sh mount [esp-part1-by-id]   # import + unlock + mount everything
#   sudo ./rescue.sh enter                     # chroot into the system (nixos-enter)
#   sudo ./rescue.sh pull                      # git pull /mnt/root/nixos
#   sudo ./rescue.sh install                   # nixos-install #CyreneMinimal
#   sudo ./rescue.sh umount                    # unmount everything + export pool
#
# 'mount' auto-detects the ESP as the -part1 of the first NVMe disk in the
# mirror unless you pass it explicitly.

set -euo pipefail

POOL="rpool"
FLAKE_ATTR="CyreneMinimal"
CMD="${1:-mount}"

# install.sh now clones into /etc/nixos; older runs used /root/nixos.
repo_dir() {
  for d in /mnt/etc/nixos /mnt/root/nixos; do
    [ -d "$d/.git" ] && { echo "$d"; return; }
  done
  echo "no repo clone found under /mnt/etc/nixos or /mnt/root/nixos" >&2
  return 1
}

# nixos-enter/nixos-install bind-mount the host's resolv.conf onto
# $mnt/etc/resolv.conf. On an installed NixOS target that path is a symlink
# (to /etc/static/... or the systemd-resolved stub) that dangles inside the
# chroot, so the bind fails and DNS is dead. Replace it with a regular file
# carrying the live ISO's resolvers before entering the chroot.
fix_resolv() {
  mkdir -p /mnt/etc
  rm -f /mnt/etc/resolv.conf
  cp -L /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null \
    || echo "nameserver 1.1.1.1" > /mnt/etc/resolv.conf
}

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

case "$CMD" in
  mount)
    ESP="${2:-}"

    if ! zpool list "$POOL" >/dev/null 2>&1; then
      # -f: the ISO's hostid never matches the installed system's
      zpool import -N -R /mnt -f "$POOL"
    fi
    if [ "$(zfs get -H -o value keystatus "$POOL")" != "available" ]; then
      zfs load-key "$POOL"
    fi

    mountpoint -q /mnt || mount -t zfs -o zfsutil "$POOL/nixos/root" /mnt
    mkdir -p /mnt/var/lib /mnt/var/log /mnt/tmp /mnt/boot
    mountpoint -q /mnt/var/lib || mount -t zfs -o zfsutil "$POOL/nixos/var/lib" /mnt/var/lib
    mountpoint -q /mnt/var/log || mount -t zfs -o zfsutil "$POOL/nixos/var/log" /mnt/var/log
    mountpoint -q /mnt/tmp     || mount -t zfs "$POOL/nixos/tmp" /mnt/tmp

    if ! mountpoint -q /mnt/boot; then
      if [ -z "$ESP" ]; then
        # ESP = -part1 sibling of a device backing the pool
        vdev=$(zpool list -v -H -P "$POOL" | awk '$1 ~ /-part2$/ {print $1; exit}')
        [ -n "$vdev" ] || { echo "could not detect ESP; pass it: $0 mount /dev/disk/by-id/...-part1" >&2; exit 1; }
        ESP="${vdev%-part2}-part1"
      fi
      mount -o umask=0077 "$ESP" /mnt/boot
    fi

    echo "--- mounted:"
    findmnt -R /mnt -o TARGET,SOURCE,FSTYPE
    echo
    echo "next: $0 enter | $0 pull | $0 install | $0 umount"
    ;;

  enter)
    fix_resolv
    exec nixos-enter --root /mnt
    ;;

  pull)
    dir=$(repo_dir)
    git -C "$dir" pull
    git -C "$dir" status --short
    ;;

  install)
    fix_resolv
    nixos-install --flake "$(repo_dir)#$FLAKE_ATTR" --no-root-passwd
    ;;

  umount)
    umount -R /mnt 2>/dev/null || true
    zpool export "$POOL"
    echo "pool exported — safe to reboot"
    ;;

  *)
    echo "usage: $0 {mount [esp-part1]|enter|pull|install|umount}" >&2
    exit 1
    ;;
esac
