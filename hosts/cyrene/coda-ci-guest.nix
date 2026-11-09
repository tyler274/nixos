{ lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];
  system.stateVersion = "26.05";
  networking.hostName = "coda-ci";
  networking.firewall.enable = true;
  networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
  networking.dhcpcd.extraConfig = "nohook resolv.conf";
  services.openssh.enable = false;
  users.users.runner = { isNormalUser = true; uid = 1000; };
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = with pkgs; [ git nix nodejs_24 bash coreutils sccache gnutar gzip ];
  virtualisation = {
    memorySize = 16384;
    cores = 8;
    graphics = false;
    diskSize = 160 * 1024;
    useNixStoreImage = true;
    mountHostNixStore = false;
    writableStore = true;
    writableStoreUseTmpfs = false;
    sharedDirectories = lib.mkForce { };
    qemu.networkingOptions = lib.mkForce [
      "-netdev user,id=net0,ipv6=off,dns=1.1.1.1"
      "-device virtio-net-pci,netdev=net0"
    ];
    qemu.options = [
      "-fw_cfg name=opt/coda/jit,file=$CODA_JIT_FILE"
      "-drive file=$CODA_CACHE_IMAGE,if=none,id=coda-cache,format=qcow2 -device virtio-blk-pci,drive=coda-cache,serial=coda-cache"
    ];
  };
  boot.kernelModules = [ "qemu_fw_cfg" ];
  boot.kernelParams = [ "console=ttyS0" ];
  systemd.services.coda-cache = {
    before = [ "coda-runner.service" ];
    requiredBy = [ "coda-runner.service" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    path = with pkgs; [ util-linux e2fsprogs coreutils ];
    script = ''
      device=/dev/disk/by-id/virtio-coda-cache
      test -b "$device"
      if ! blkid "$device"; then
        mkfs.ext4 -m 0 "$device"
      fi
      mkdir -p /var/cache/sccache
      mount -o nodev,nosuid,noexec "$device" /var/cache/sccache
      chown runner:users /var/cache/sccache
      install -d -o runner -g users -m 0700 /var/lib/coda-runner
      install -o runner -g users -m 0400 /sys/firmware/qemu_fw_cfg/by_name/opt/coda/jit/raw /var/lib/coda-runner/jit
    '';
  };
  systemd.services.coda-runner = {
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "coda-cache.service" ];
    environment = {
      HOME = "/var/lib/coda-runner";
      RUNNER_ROOT = "/var/lib/coda-runner";
      SCCACHE_DIR = "/var/cache/sccache";
      SCCACHE_CACHE_SIZE = "40G";
      CARGO_INCREMENTAL = "0";
      RUSTC_WRAPPER = "sccache";
    };
    path = with pkgs; [ git nix nodejs_24 bash coreutils sccache gnutar gzip ];
    serviceConfig = {
      User = "runner";
      WorkingDirectory = "/var/lib/coda-runner";
      Restart = "no";
      RuntimeMaxSec = "3h";
      ExecStopPost = "+${pkgs.systemd}/bin/systemctl poweroff --no-block";
    };
    script = ''
      exec ${pkgs.github-runner}/bin/Runner.Listener run --jitconfig "$(cat jit)"
    '';
  };
}
