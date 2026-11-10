# Disposable Firecracker guest used before enabling the CI controller.
{ pkgs, ... }:
{
  system.stateVersion = "26.05";
  networking.hostName = "coda-ci-prototype";
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.nameservers = [ "1.1.1.1" ];
  # Firecracker exposes virtio-net over PCI, so the guest name is predictable
  # (enp0sN), not eth0; match the tap's MAC instead.
  systemd.network.networks."10-tap" = {
    matchConfig.MACAddress = "02:00:00:00:01:02";
    address = [ "10.234.0.2/30" ];
    routes = [{ Gateway = "10.234.0.1"; }];
  };
  services.openssh.enable = false;
  microvm = {
    hypervisor = "firecracker";
    socket = "firecracker.sock";
    vcpu = 2;
    mem = 2048;
    shares = [ ];
    interfaces = [{ type = "tap"; id = "fc-coda-ci"; mac = "02:00:00:00:01:02"; }];
    volumes = [{ image = "work.img"; mountPoint = "/var/lib/docker"; size = 4096; }];
  };
  virtualisation.docker.enable = true;
  environment.systemPackages = [ pkgs.act pkgs.curl ];
  systemd.services.coda-prototype = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    after = [ "docker.service" "network-online.target" ];
    path = [ pkgs.docker pkgs.iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      docker info
      ip route get 1.1.1.1
      test ! -e /agents/coda/src
      test ! -e /run/agent-secrets
      echo CODA_FIRECRACKER_DOCKER_READY
    '';
  };
}
