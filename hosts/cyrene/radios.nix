{ lib, ... }:

{
  # Cyrene is a wired-only workstation: no Bluetooth, no Wi-Fi. Kill the
  # radio stacks at the kernel level rather than just leaving them unused.

  # Override desktop-common.nix, which enables bluez for desktop hosts.
  hardware.bluetooth.enable = lib.mkForce false;

  # "blacklist" only stops udev alias autoloading; a module can still be
  # pulled in as a dependency or loaded explicitly.
  boot.blacklistedKernelModules = [
    # Bluetooth core + transports/vendor drivers
    "bluetooth"
    "btusb"
    "btintel"
    "btrtl"
    "btbcm"
    "btmtk"
    "bnep"
    "rfcomm"
    "hidp"

    # Wi-Fi: every driver depends on these stacks, so blocking them
    # covers whatever card is present without naming its driver.
    "cfg80211"
    "mac80211"
  ];

  # module_blacklist= is the hard block: the kernel refuses to load these
  # even as dependencies of other modules or via explicit modprobe.
  boot.kernelParams = [
    "module_blacklist=bluetooth,btusb,btintel,btrtl,btbcm,btmtk,bnep,rfcomm,hidp,cfg80211,mac80211"
  ];
}
