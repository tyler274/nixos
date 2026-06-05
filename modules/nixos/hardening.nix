{
  # Prevent replacing the running kernel image (blocks kexec attacks).
  security.protectKernelImage = true;

  # Force Page Table Isolation; mitigates Meltdown on Intel, harmless no-op on
  # unaffected AMD CPUs (the hardware detection will skip it there).
  security.forcePageTableIsolation = true;

  # Hardening kernel params recommended by https://wiki.nixos.org/wiki/NixOS_Hardening
  boot.kernelParams = [
    # Don't merge slab caches — makes heap spray harder.
    "slab_nomerge"

    # Overwrite freed pages with 0xAA to catch use-after-free bugs.
    "page_poison=1"

    # Randomise page allocator freelist order to hinder predictable allocation.
    "page_alloc.shuffle=1"

    # Disable debugfs; reduces kernel attack surface at runtime.
    "debugfs=off"
  ];

  boot.kernel.sysctl = {
    # Hide kernel symbol addresses even from CAP_SYSLOG holders.
    # "kernel.kptr_restrict" = "2";

    # Disable the BPF JIT compiler to eliminate JIT-spray attacks.
    # "net.core.bpf_jit_enable" = false;

    # Disable ftrace; it exposes detailed kernel internals to root.
    # "kernel.ftrace_enabled" = false;

    # Disable io_uring entirely — it has been a prolific kernel CVE source.
    # If an application breaks (check with: journalctl -xe | grep io_uring),
    # set to 1 (restrict to privileged) or 0 (allow all) as needed.
    # "kernel.io_uring_disabled" = 2;

    # Log and drop packets that have no plausible route back out the same
    # interface (strict reverse-path filtering, RFC 3704).
    "net.ipv4.conf.all.log_martians" = true;
    "net.ipv4.conf.all.rp_filter" = "1";
    "net.ipv4.conf.default.log_martians" = true;
    "net.ipv4.conf.default.rp_filter" = "1";

    # Ignore broadcast ICMP echo requests (mitigates SMURF amplification).
    "net.ipv4.icmp_echo_ignore_broadcasts" = true;

    # Reject incoming ICMP redirect messages on all interfaces; an attacker
    # on the same LAN could otherwise poison the routing table.
    "net.ipv4.conf.all.accept_redirects" = false;
    "net.ipv4.conf.all.secure_redirects" = false;
    "net.ipv4.conf.default.accept_redirects" = false;
    "net.ipv4.conf.default.secure_redirects" = false;
    "net.ipv6.conf.all.accept_redirects" = false;
    "net.ipv6.conf.default.accept_redirects" = false;

    # Don't send ICMP redirects (we are not a router).
    "net.ipv4.conf.all.send_redirects" = false;
    "net.ipv4.conf.default.send_redirects" = false;
  };
}
