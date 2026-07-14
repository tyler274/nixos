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

    # Zero heap/stack allocations before handing them out, so stale data can't
    # leak between allocations. (init_on_free is deliberately omitted:
    # page_poison=1 above already covers the free path.)
    "init_on_alloc=1"

    # Randomise the kernel stack offset on each syscall entry; breaks exploits
    # that rely on a deterministic stack layout.
    "randomize_kstack_offset=on"

    # Remove the legacy fixed-address vsyscall page — a classic ROP gadget
    # source. Only ancient (pre-2013 glibc) binaries need it.
    "vsyscall=none"
  ];

  # Legacy/exotic network protocols nothing on a desktop uses, but which have
  # a long CVE history (remotely triggerable if a listener ever appears).
  boot.blacklistedKernelModules = [
    "dccp"
    "sctp"
    "rds"
    "tipc"
    "n-hdlc"
  ];

  # Only members of wheel may execute the sudo binary at all; a compromised
  # service account can't even probe it for vulnerabilities.
  security.sudo.execWheelOnly = true;

  boot.kernel.sysctl = {
    # Hide kernel symbol addresses even from CAP_SYSLOG holders.
    "kernel.kptr_restrict" = "2";

    # Restrict dmesg to root; kernel logs leak pointers and hardware details
    # useful for exploit development.
    "kernel.dmesg_restrict" = "1";

    # Only root may load BPF programs (kills the unprivileged-BPF exploit
    # class), and harden the JIT output for the programs root does load.
    # Softer than disabling the JIT outright, which would hurt systemd and
    # firewall performance.
    "kernel.unprivileged_bpf_disabled" = "1";
    "net.core.bpf_jit_harden" = "2";

    # Processes may only be ptraced by their direct ancestors (Yama level 1):
    # a compromised process can't read the memory of unrelated processes.
    # Running gdb/strace under the debuggee's parent still works; attaching to
    # an arbitrary running PID now needs sudo.
    "kernel.yama.ptrace_scope" = "1";

    # Deny perf_event_open() to unprivileged users; the perf subsystem is a
    # recurring source of side-channel and privilege-escalation bugs. Lower
    # temporarily to 2 (or 1) when actually profiling with `perf`.
    "kernel.perf_event_paranoid" = "3";

    # Keep only the sync/remount-read-only SysRq functions (bit 4|16 = 20 is
    # not needed; 16 = sync). Full SysRq lets anyone at the console kill
    # processes or trigger crashes.
    "kernel.sysrq" = "16";

    # Unprivileged userfaultfd has been a building block in many use-after-free
    # exploits (it lets an attacker pause kernel code mid-copy). Root only.
    "vm.unprivileged_userfaultfd" = "0";

    # Don't auto-load obscure TTY line disciplines (another historic CVE pit);
    # anything legitimate loads its module explicitly with CAP_SYS_MODULE.
    "dev.tty.ldisc_autoload" = "0";

    # Disallow O_CREAT in world-writable sticky dirs when the existing
    # FIFO/regular file isn't owned by the opener — blocks /tmp squatting
    # attacks against sloppy scripts.
    "fs.protected_fifos" = "2";
    "fs.protected_regular" = "2";

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

    # Refuse source-routed packets (sender-dictated routing; spoofing aid).
    "net.ipv4.conf.all.accept_source_route" = false;
    "net.ipv4.conf.default.accept_source_route" = false;
    "net.ipv6.conf.all.accept_source_route" = false;
    "net.ipv6.conf.default.accept_source_route" = false;

    # Drop RST-during-TIME-WAIT (RFC 1337 fix); mitigates off-path connection
    # reset attacks.
    "net.ipv4.tcp_rfc1337" = "1";
  };
}
