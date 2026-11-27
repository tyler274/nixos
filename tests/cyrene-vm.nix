# Full Cyrene software configuration with virtual hardware; not a Secure Boot,
# NVIDIA or physical ZFS-pool test. SSH inputs must already be accessible.
let
  flake = builtins.getFlake (toString ../.);
  host = flake.nixosConfigurations.Cyrene;
in
assert !(host.config.fileSystems ? "/home/luluco/.cache");
assert builtins.elem "d /home/luluco/.cache 0700 luluco users -" host.config.systemd.tmpfiles.rules;
assert !(host.config.cyrene.agentsPool.mounts ? "agents/coda/host");
assert host.config.cyrene.agentsPool.optionalMounts."agents/coda/host" == "/agents/coda/host";
host.extendModules {
  modules = [ ({ lib, modulesPath, ... }: {
    imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];
    virtualisation = { memorySize = 4096; cores = 2; diskSize = 8192; graphics = true; };
    services.xserver.videoDrivers = lib.mkOverride 40 [ "modesetting" ];
    hardware.nvidia-container-toolkit.enable = lib.mkForce false;
    environment.etc.crypttab.text = lib.mkForce "";
    boot.zswap.enable = lib.mkForce false;
    # The host's 2 GiB watermark starves a 4 GiB VM before SDDM can settle.
    boot.kernel.sysctl."vm.min_free_kbytes" = lib.mkForce 65536;
    zramSwap.enable = true;
    zramSwap.memoryPercent = 50;
    boot.zfs.requestEncryptionCredentials = lib.mkForce false;
    services.displayManager.autoLogin.enable = lib.mkForce false;
    services.smartd.enable = lib.mkForce false;
    power.ups.enable = lib.mkForce false;
    systemd.timers.docker-zfs-cleanup.enable = lib.mkForce false;
  }) ];
}
