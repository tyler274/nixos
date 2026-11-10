{ lib, ... }:

# The coda-agent sandbox: where coding agents (and you, over Remote-SSH) work
# on coda-rust worktrees kept on the agents pool. See
# modules/nixos/agent-sandbox.nix for what the sandbox guarantees.
#
# Paths inside the container equal the host paths, so GC roots the host Nix
# daemon records for a worktree's dev shell stay valid from the host's view.
let
  inherit (import ./zfs/lib.nix { inherit lib; }) agentsPoolCreated;
  uidBase = 655360;
  hostAgentUid = uidBase + 1000;
  hostUsersGid = uidBase + 100;
  repo = "/agents/coda/src/coda-rust";
in
lib.mkIf agentsPoolCreated {
  agentSandbox.containers.coda-agent = {
    inherit uidBase;
    hostAddress = "10.233.1.1";
    localAddress = "10.233.1.2";
    autoStart = true;
    requires = [ "agents-pool.service" ];
    memoryMax = "24G";
    memoryHigh = "20G";
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBeBvlXnNHWV5nhvbyvTG0xe+41dxNtX9l/QRPDqOD8s coda-agent"
    ];
    binds = {
      "/agents/coda/src" = {
        hostPath = "/agents/coda/src";
        ownedByAgent = true;
      };
      "/agents/coda/build" = {
        hostPath = "/agents/coda/build";
        ownedByAgent = true;
      };
      "/agents/coda/ci/requests" = {
        hostPath = "/agents/coda/ci/spool/requests";
        ownedByAgent = true;
      };
      "/agents/coda/ci/results" = {
        hostPath = "/agents/coda/ci/spool/results";
        readOnly = true;
      };
      # Bundles of the host worktrees written by coda-carry. Kept off the
      # agent-owned tree, so the host never writes where the agent can
      # plant a symlink.
      "/agents/coda/carry" = {
        hostPath = "/var/lib/coda-carry";
        readOnly = true;
      };
      "/run/agent-secrets" = {
        hostPath = "/var/lib/agent-secrets/coda-agent";
        readOnly = true;
      };
    };
    config = import ./agent-container-guest.nix { inherit repo; };
  };

  # Token files are placed by hand (README: "Agent sandbox credentials").
  # The agent may read them; nothing in the container can change them.
  systemd.tmpfiles.rules = [
    "d /var/lib/agent-secrets 0711 root root -"
    "d /var/lib/agent-secrets/coda-agent 0750 root ${toString hostUsersGid} -"
    "d /var/lib/coda-carry 0755 root root -"
  ];

  # Spool directories are made after the pool is mounted, never by tmpfiles
  # at boot (that would write under the empty mountpoints on rpool).
  systemd.services."container@coda-agent".preStart = lib.mkBefore ''
    install -d -m 0755 -o root -g root /agents/coda/ci/spool /agents/coda/ci/spool/results
  '';

  environment.etc."coda-agent/uid".text = toString hostAgentUid;
}
