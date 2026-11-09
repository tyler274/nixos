{ config, lib, pkgs, ... }:
let
  cfg = config.services.coda-ci;
  guest = import (pkgs.path + "/nixos") {
    system = "x86_64-linux";
    configuration = ./coda-ci-guest.nix;
  };
  controller = pkgs.writeShellApplication {
    name = "coda-ci-controller";
    runtimeInputs = with pkgs; [ python3 qemu coreutils ];
    text = ''exec python3 ${./coda_ci.py}'';
  };
in
{
  options.services.coda-ci = {
    enable = lib.mkEnableOption "isolated Coda qualification on Cyrene";
    tokenFile = lib.mkOption { type = lib.types.str; default = "/run/secrets/coda-runner-token"; };
  };
  config = lib.mkIf cfg.enable {
    users.groups.coda-ci = { };
    users.users.coda-ci = {
      isSystemUser = true;
      group = "coda-ci";
      extraGroups = [ "kvm" ];
    };
    networking.nftables.preCheckRuleset = lib.mkAfter ''
      sed 's/meta skuid "coda-ci"/meta skuid 65534/g' -i ruleset.conf
    '';
    networking.nftables.tables.coda-ci = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority -10; policy accept;
          meta skuid "coda-ci" fib daddr type local reject
        }
      '';
    };
    systemd.services.coda-ci = {
      description = "Run one approved Coda job in a disposable VM";
      after = [ "network-online.target" "nftables.service" "coda-scratch-directories.service" "coda-cache-directories.service" ];
      requires = [ "nftables.service" "coda-scratch-directories.service" "coda-cache-directories.service" ];
      bindsTo = [ "nftables.service" "var-cache-coda\\x2dencrypted.mount" ];
      unitConfig.RequiresMountsFor = [ "/nix/var/nix/builds" "/var/cache/coda-encrypted" ];
      environment = {
        CODA_CI_VM = "${guest.config.system.build.vm}/bin/run-coda-ci-vm";
        CODA_CI_SCRATCH = "/nix/var/nix/builds/coda/ci";
        CODA_CI_CACHE = "/var/cache/coda-encrypted/ci";
      };
      serviceConfig = {
        Type = "oneshot";
        User = "coda-ci";
        Group = "coda-ci";
        ExecStart = lib.getExe controller;
        LoadCredential = "github-token:${cfg.tokenFile}";
        RuntimeMaxSec = "3h10m";
        TimeoutStartSec = "3h10m";
        KillMode = "control-group";
        UMask = "0077";
        MemoryMax = "20G";
        MemorySwapMax = 0;
        CPUQuota = "800%";
        Nice = 10;
        TasksMax = 2048;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_NETLINK" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        CapabilityBoundingSet = "";
        BindReadOnlyPaths = [ "${pkgs.writeText "coda-ci-resolv.conf" "nameserver 1.1.1.1\nnameserver 9.9.9.9\n"}:/etc/resolv.conf" ];
        ReadWritePaths = [ "/nix/var/nix/builds/coda/ci" "/var/cache/coda-encrypted/ci" ];
        InaccessiblePaths = [ "/nix/var/nix/daemon-socket" "/run/docker.sock" ];
        DevicePolicy = "closed";
        DeviceAllow = [ "/dev/kvm rw" ];
        IPAddressDeny = [
          "localhost" "link-local" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
          "100.64.0.0/10" "0.0.0.0/8" "224.0.0.0/4" "240.0.0.0/4" "::/0"
        ];
      };
    };
    systemd.timers.coda-ci = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "2m"; OnUnitInactiveSec = "1m"; };
    };
    systemd.services.coda-scratch-directories.script = lib.mkAfter ''
      chown coda-ci:coda-ci /nix/var/nix/builds/coda/ci
    '';
    systemd.services.coda-cache-directories.script = lib.mkAfter ''
      chown coda-ci:coda-ci /var/cache/coda-encrypted/ci
    '';
  };
}
