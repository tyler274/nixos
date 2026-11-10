{ guest }:
{ pkgs, ... }:
{
  name = "coda-firecracker";
  nodes.machine = { ... }: {
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.qemu.options = [ "-cpu host" ];
    environment.systemPackages = [ pkgs.iproute2 guest ];
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    with subtest("nested KVM is available"):
        machine.succeed("test -c /dev/kvm")
    with subtest("Firecracker boots with a private tap and Docker"):
        machine.succeed("ip tuntap add fc-coda-ci mode tap")
        machine.succeed("ip addr add 10.234.0.1/30 dev fc-coda-ci")
        machine.succeed("ip link set fc-coda-ci up")
        machine.succeed("mkdir /tmp/firecracker")
        machine.succeed("systemd-run --unit=firecracker --property=WorkingDirectory=/tmp/firecracker ${guest}/bin/microvm-run")
        machine.wait_until_succeeds("journalctl -u firecracker --no-pager | grep CODA_FIRECRACKER_DOCKER_READY", timeout=180)
        machine.succeed("systemctl stop firecracker")
        machine.fail("systemctl is-active firecracker")
  '';
}
