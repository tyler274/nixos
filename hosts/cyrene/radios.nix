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

    # Realtek Wi-Fi driver cores, blocked explicitly as belt-and-suspenders
    # (they can't load anyway with cfg80211/mac80211 blacklisted above).
    # Covers PCIe/USB/SDIO dongles: rtlwifi (rtl8192xx-era), rtl8xxxu
    # (USB), rtw88 (RTL8822/8821), rtw89 (RTL8852/8851).
    "rtlwifi"
    "rtl_pci"
    "rtl_usb"
    "rtl8xxxu"
    "rtw88_core"
    "rtw88_pci"
    "rtw88_usb"
    "rtw88_sdio"
    "rtw89_core"
    "rtw89_pci"
  ];

  # module_blacklist= is the hard block: the kernel refuses to load these
  # even as dependencies of other modules or via explicit modprobe.
  boot.kernelParams = [
    "module_blacklist=bluetooth,btusb,btintel,btrtl,btbcm,btmtk,bnep,rfcomm,hidp,cfg80211,mac80211,rtlwifi,rtl_pci,rtl_usb,rtl8xxxu,rtw88_core,rtw88_pci,rtw88_usb,rtw88_sdio,rtw89_core,rtw89_pci"
  ];
}
