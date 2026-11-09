set -euo pipefail
umask 077
image=/var/cache/ccache/coda/cache.luks
mapping=coda-cache
mount=/var/cache/coda-encrypted

require_cache_disk() {
  actual=$(findmnt -rn -M /var/cache/ccache -o SOURCE)
  expected=/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B-part1
  test "$(readlink -f "$actual")" = "$(readlink -f "$expected")" || {
    echo 'Cache NVMe is not mounted. Refusing to write.' >&2
    exit 1
  }
}

case "${1:-status}" in
  create)
    test "$EUID" = 0
    require_cache_disk
    install -d -m 0700 /var/cache/ccache/coda
    test ! -e "$image" && test ! -L "$image"
    test "${2:-}" = --confirm-new-image || {
      echo 'Creates a new 256 GiB encrypted image, not a physical partition. Pass --confirm-new-image.' >&2
      exit 1
    }
    (set -o noclobber; : > "$image")
    fallocate -l 256G "$image"
    cryptsetup luksFormat --type luks2 "$image"
    cryptsetup open "$image" "$mapping"
    trap 'cryptsetup close "$mapping"' EXIT
    mkfs.ext4 -m 0 "/dev/mapper/$mapping"
    echo 'Encrypted cache created. Run coda-storage unlock to mount it.'
    ;;
  unlock)
    test "$EUID" = 0
    require_cache_disk
    test -f "$image" && test ! -L "$image"
    cryptsetup isLuks "$image"
    if ! test -e "/dev/mapper/$mapping"; then
      cryptsetup open "$image" "$mapping"
    fi
    systemctl start 'var-cache-coda\x2dencrypted.mount'
    systemctl start coda-cache-directories.service
    if systemctl cat coda-ci.timer >/dev/null 2>&1; then
      systemctl start coda-ci.timer
    fi
    ;;
  lock)
    test "$EUID" = 0
    if systemctl cat coda-ci.service >/dev/null 2>&1; then
      systemctl stop coda-ci.timer coda-ci.service
    fi
    systemctl stop coda-cache-directories.service
    systemctl stop 'var-cache-coda\x2dencrypted.mount'
    cryptsetup close "$mapping"
    ;;
  status)
    findmnt -M /nix/var/nix/builds
    findmnt -M "$mount"
    ;;
  *)
    echo 'Usage: coda-storage {create --confirm-new-image|unlock|lock|status}' >&2
    exit 2
    ;;
esac
