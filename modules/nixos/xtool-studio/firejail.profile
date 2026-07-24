# Firejail profile for xTool Studio (the Windows build run under Wine). Only
# used when programs.xtool-studio.sandbox = "firejail"; the default backend is
# bubblewrap, baked into the launcher (see default.nix). Kept as an option
# for hosts that already standardise on firejail for their other GUI apps.
#
# Goal: confine the proprietary vendor blob as much as possible while keeping
# the two things it genuinely needs — a GPU-backed X11 GUI and unrestricted
# LAN access to reach the M2. Several "obvious" hardening knobs are deliberately
# left OFF because they break this specific workload; each is noted below so the
# tradeoff is explicit rather than accidental.
#
# NB: assumes the default state dir ~/.local/share/xtool-studio (the launcher
# honours XTOOL_STUDIO_HOME / XDG_DATA_HOME, but a firejail profile is static
# and can only whitelist the default path); override via the .local include if
# you relocate it. User overrides go in ~/.config/firejail/xtool-studio.local.
include xtool-studio.local

# --- filesystem -----------------------------------------------------------
# Maintained blacklists for credentials, keyrings, other apps' config, etc.
# NB: disable-exec.inc is intentionally NOT included — it marks ${HOME}/tmp
# noexec, which would stop Wine from mapping the DLLs/EXEs in its prefix.
# (disable-passwdmgr.inc was folded into disable-common.inc as of firejail
# 0.9.80, so it is not included separately.)
include disable-common.inc
include disable-programs.inc

# Whitelist model: everything in $HOME is hidden except the prefix/state dir
# and the usual spots a user imports art from. Add more via the .local include.
mkdir ${HOME}/.local/share/xtool-studio
whitelist ${HOME}/.local/share/xtool-studio
whitelist ${DOWNLOADS}
whitelist ${DOCUMENTS}
whitelist ${DESKTOP}
whitelist ${PICTURES}
whitelist ${HOME}/Projects
# Fonts so the UI renders; the store paths stay readable outside $HOME.
whitelist ${HOME}/.fonts
whitelist ${HOME}/.local/share/fonts
include whitelist-common.inc

# Display: Wine prefers its Wayland driver (see wineRegistry in default.nix).
# The Wayland socket in ${RUNUSER} is left reachable (not whitelisted away),
# and private-tmp keeps /tmp/.X11-unix for the XWayland/X11 fallback.
private-tmp
private-cache
# private-dev keeps a minimal /dev but retains dri (GPU) and snd (sound),
# which Wine's Wayland/X11 + OpenGL path and Studio's audio need.
private-dev
machine-id
disable-mnt

# --- privileges / kernel attack surface -----------------------------------
caps.drop all
noroot
nonewprivs
nogroups
seccomp
restrict-namespaces
# D-Bus: none. This is a Windows Electron under Wine, so it never speaks to the
# host session/system bus; cutting it off removes a large surface for free.
dbus-user none
dbus-system none

# Protocols: unix (X11, wineserver), inet/inet6 (device TCP + multicast
# discovery), netlink (Wine/interface enumeration). No AF_PACKET, etc.
protocol unix,inet,inet6,netlink

# --- deliberately NOT enabled (would break the app) -----------------------
# net <iface>            : a private net namespace kills the LAN multicast the
#                          M2 discovery relies on — we must share host net.
# memory-deny-write-execute : breaks V8's JIT and Wine's code generation.
# apparmor               : no xtool-studio AppArmor profile is loaded here.
# nosound / no3d         : Studio uses both.
