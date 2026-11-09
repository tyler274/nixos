# Prototype and regression test for the agent sandbox and the agents pool:
#   nix build .#checks.x86_64-linux.agent-sandbox -L
# Runs in a throwaway VM with a blank disk; nothing on the host is touched.
{ pkgs, ... }:
let
  disk = "/dev/disk/by-id/virtio-agents";
  uidBase = 655360;
  hostAgent = toString (uidBase + 1000);
in
{
  name = "agent-sandbox";

  nodes.machine =
    { config, lib, pkgs, ... }:
    {
      imports = [
        ../hosts/cyrene/zfs/agents.nix
        ../modules/nixos/agent-sandbox.nix
      ];
      virtualisation = {
        memorySize = 3072;
        cores = 4;
        writableStore = true;
        emptyDiskImages = [
          {
            size = 4096;
            driveConfig.deviceExtraOpts.serial = "agents";
          }
          {
            size = 8192;
            driveConfig.deviceExtraOpts.serial = "store";
          }
        ];
      };
      boot.supportedFilesystems = [ "zfs" ];
      networking.hostId = "8425e349";
      networking.nftables.enable = true;
      virtualisation.docker.enable = false;
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      nix.settings.allowed-users = [ "@users" ];
      environment.systemPackages = [ pkgs.gptfdisk ];

      # The VM's virtiofs/overlay store can't be idmapped. Cyrene's store is
      # on ZFS, so after the first boot the test copies the store onto a ZFS
      # pool and this unit binds it over /nix/store on later boots.
      systemd.services.vm-zfs-store = {
        wantedBy = [ "multi-user.target" ];
        before = [ "container@coda-agent.service" "nix-daemon.service" ];
        requiredBy = [ "container@coda-agent.service" ];
        after = [ "local-fs.target" ];
        unitConfig.ConditionPathExists = "/dev/disk/by-id/virtio-store";
        path = [ config.boot.zfs.package pkgs.util-linux ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          zpool list vmstore >/dev/null 2>&1 || zpool import -N -o cachefile=none vmstore || exit 0
          zfs mount vmstore/store 2>/dev/null || true
          findmnt -rn -M /nix/store -o SOURCE | grep -q vmstore || mount --bind /vmstore/store /nix/store
        '';
      };

      cyrene.agentsPool = {
        enable = true;
        inherit disk;
      };

      agentSandbox.containers.coda-agent = {
        inherit uidBase;
        autoStart = true;
        hostAddress = "10.233.1.1";
        localAddress = "10.233.1.2";
        requires = [ "agents-pool.service" ];
        memoryMax = "1G";
        binds = {
          "/work/src" = {
            hostPath = "/agents/coda/src";
            ownedByAgent = true;
          };
          "/work/build" = {
            hostPath = "/agents/coda/build";
            ownedByAgent = true;
          };
          "/run/agent-secrets" = {
            hostPath = "/run/agent-secrets/coda-agent";
            readOnly = true;
          };
        };
      };
      systemd.tmpfiles.rules = [
        "d /run/agent-secrets/coda-agent 0750 ${hostAgent} ${toString (uidBase + 100)} -"
        "f /run/agent-secrets/coda-agent/token 0440 ${hostAgent} ${toString (uidBase + 100)} - secret"
      ];
      # Host services the sandbox must not reach.
      services.nginx = {
        enable = true;
        virtualHosts.default.listen = [
          {
            addr = "0.0.0.0";
            port = 8080;
          }
        ];
      };
      # Open on the host firewall, so only the sandbox rules can block it.
      networking.firewall.allowedTCPPorts = [ 8080 ];
      users.users.luluco = {
        isNormalUser = true;
        home = "/home/luluco";
      };
    };

  testScript = ''
    import json

    in_agent = "nixos-container run coda-agent -- su -l agent -c "

    def agent(cmd):
        return machine.succeed(in_agent + json.dumps(cmd))

    def agent_fails(cmd):
        machine.fail(in_agent + json.dumps(cmd))

    machine.start()

    with subtest("boot does not wait for or need the pool"):
        machine.wait_for_unit("multi-user.target")
        machine.succeed("systemctl is-failed agents-pool.service")
        machine.fail("systemctl is-active container@coda-agent.service")

    with subtest("create the pool as agents.nix documents"):
        machine.succeed(
            "zpool create -o ashift=12 -o autotrim=on -o cachefile=none"
            " -O compression=zstd -O atime=off -O xattr=sa -O acltype=posix"
            " -O mountpoint=none -O canmount=off agents ${disk}",
            "install -d -m 0700 /etc/zfs/keys",
            "dd if=/dev/urandom of=/etc/zfs/keys/agents-coda.key bs=32 count=1",
            "zfs create -o encryption=aes-256-gcm -o keyformat=raw"
            " -o keylocation=file:///etc/zfs/keys/agents-coda.key"
            " -o canmount=off -o mountpoint=none agents/coda",
            "for d in src build ci; do zfs create -o mountpoint=/agents/coda/$d agents/coda/$d; done",
            "zpool export agents",
            "zpool create -o cachefile=none -O compression=lz4 -O mountpoint=none vmstore /dev/disk/by-id/virtio-store",
            "zfs create -o mountpoint=/vmstore/store vmstore/store",
            "cp -a /nix/store/. /vmstore/store/",
            "zpool export vmstore",
        )

    with subtest("reboot: pool imports late, unlocks from the key, container starts"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("agents-pool.service")
        machine.succeed("findmnt -rn -M /agents/coda/src -o SOURCE | grep -qx agents/coda/src")
        machine.succeed("findmnt -rn -M /nix/store -o SOURCE | grep -q vmstore")
        machine.wait_for_unit("container@coda-agent.service")

    with subtest("missing key fails only the pool and container, not boot"):
        machine.succeed("mv /etc/zfs/keys/agents-coda.key /root/key")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("systemctl is-failed agents-pool.service")
        machine.fail("systemctl is-active container@coda-agent.service")
        machine.succeed("mv /root/key /etc/zfs/keys/agents-coda.key")
        machine.succeed("systemctl restart agents-pool.service")
        machine.succeed("systemctl start container@coda-agent.service")

    with subtest("user namespace: agent is an unmapped high UID on the host"):
        agent("touch /work/src/probe")
        uid = machine.succeed("stat -c %u /agents/coda/src/probe").strip()
        assert uid == "${hostAgent}", uid
        # Only nss-mymachines' synthetic name; no host account.
        machine.fail("grep -q ':${hostAgent}:' /etc/passwd")
        machine.succeed("getent passwd ${hostAgent} | grep -q '^vu-coda-agent-1000:'")

    with subtest("host git refuses a tree the agent wrote"):
        agent("git init -q /work/src/repo")
        machine.fail("su luluco -c 'git -C /agents/coda/src/repo status'")

    with subtest("reflink inside the build bind shares blocks"):
        agent("head -c 64M /dev/urandom > /work/build/seed && sync")
        before = int(machine.succeed("zpool get -Hp -o value bclonesaved agents"))
        agent("cp --reflink=always /work/build/seed /work/build/clone && sync")
        machine.sleep(6)
        after = int(machine.succeed("zpool get -Hp -o value bclonesaved agents"))
        assert after - before >= 60 * 1024 * 1024, (before, after)

    with subtest("host nix daemon from the userns container"):
        agent("nix store info")
        agent("nix path-info ${pkgs.coreutils}")
        agent_fails("touch /nix/store/escape")

    with subtest("secrets are read-only, home is absent"):
        agent("cat /run/agent-secrets/token")
        agent_fails("touch /run/agent-secrets/x")
        agent_fails("ls /home/luluco")

    with subtest("Landlock works inside nspawn"):
        agent("${pkgs.landrun}/bin/landrun --best-effort --rox /nix --ro /etc -- ${pkgs.coreutils}/bin/true")
        agent_fails("${pkgs.landrun}/bin/landrun --best-effort --rox /nix -- ${pkgs.coreutils}/bin/cat /work/src/probe")

    with subtest("network: host and private ranges blocked"):
        machine.succeed("curl -s -o /dev/null http://127.0.0.1:8080/")
        agent_fails("curl -s -m 3 http://10.233.1.1:8080/")
        agent_fails("curl -s -m 3 http://10.0.2.15:8080/")
        agent_fails("curl -s -m 3 http://192.168.1.1/")
        agent_fails("curl -s -m 3 http://100.100.100.100/")
        agent_fails("curl -s -m 3 http://169.254.169.254/")
        # Traffic toward the outside is forwarded and masqueraded.
        machine.succeed("nft list table inet agent-sandbox")
        machine.succeed("nft list table ip nixos-nat | grep -q ve-coda-agent")

    with subtest("no privilege inside"):
        agent_fails("sudo true")
        agent_fails("docker ps")
  '';
}
