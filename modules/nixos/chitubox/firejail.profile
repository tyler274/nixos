# Firejail profile for CHITUBOX (the Windows build run under Wine). Only used
# when programs.chitubox.sandbox = "firejail"; the default backend is
# bubblewrap, baked into the launcher (see default.nix). Kept as an option
# for hosts that already standardise on firejail for their other GUI apps.
#
# Same goals and tradeoffs as the xtool-studio profile next door: confine the
# proprietary vendor blob while keeping a GPU-backed GUI, cloud login (the
# app requires a CHITU account) and LAN access for send-to-printer. The
# launcher-driven QtIFW install (see default.nix) also runs confined by this
# profile, since it is invoked from inside the wrapped launcher.
#
# NB: assumes the default XDG dirs ~/.local/share/chitubox (data: the
# wineprefix, which contains the installed app under drive_c/chitubox) and
# ~/.local/state/chitubox (state: logs + stamps). The launcher honours
# CHITUBOX_HOME / XDG_DATA_HOME / XDG_STATE_HOME, but a firejail profile is
# static and can only whitelist the default paths; override via the .local
# include if you relocate them. User overrides go in
# ~/.config/firejail/chitubox.local.
include chitubox.local

# --- filesystem -----------------------------------------------------------
# Maintained blacklists for credentials, keyrings, other apps' config, etc.
# NB: disable-exec.inc is intentionally NOT included — it marks ${HOME}/tmp
# noexec, which would stop Wine from mapping the DLLs/EXEs in its prefix.
include disable-common.inc
include disable-programs.inc

# Whitelist model: everything in $HOME is hidden except the prefix/state dir
# and the usual spots a user imports models from. ${DOWNLOADS} is writable
# (not read-only) on purpose: exported .ctb/.goo job files have to land
# somewhere reachable from outside the sandbox. Add more via the .local
# include.
mkdir ${HOME}/.local/share/chitubox
whitelist ${HOME}/.local/share/chitubox
mkdir ${HOME}/.local/state/chitubox
whitelist ${HOME}/.local/state/chitubox
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
# private-dev keeps a minimal /dev but retains dri (GPU) and snd (sound).
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
# D-Bus: none. This is a Windows Qt app under Wine, so it never speaks to the
# host session/system bus; cutting it off removes a large surface for free.
dbus-user none
dbus-system none

# Protocols: unix (X11, wineserver), inet/inet6 (cloud login TLS + LAN
# send-to-printer), netlink (Wine/interface enumeration). No AF_PACKET, etc.
protocol unix,inet,inet6,netlink

# --- deliberately NOT enabled (would break the app) -----------------------
# net <iface>            : a private net namespace kills the LAN broadcast
#                          discovery for send-to-printer — share host net.
# memory-deny-write-execute : breaks QtWebEngine's V8 JIT and Wine's codegen.
# apparmor               : no chitubox AppArmor profile is loaded here.
# nosound / no3d         : the 3D viewport needs GL; keep sound for parity.
