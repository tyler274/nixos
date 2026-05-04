# nixos

Multi-host NixOS flake for Tyler's machines. Home Manager is the primary configuration surface for anything user-facing; the NixOS modules are kept as small as possible and only carry things that genuinely need root (boot, kernel, hardware, system services, SUID wrappers, system users).

## Layout

```
.
├── flake.nix                       root flake; declares all nixosConfigurations
├── modules/
│   ├── nixos/
│   │   ├── common.nix              nix settings, locale, security floor, HM wiring
│   │   └── desktop-common.nix      Plasma 6, pipewire, printing, firejail, steam, portals
│   └── home/
│       ├── common.nix              bash, git, ssh, direnv, starship, htop, CLI tools, xdg
│       └── desktop.nix             GUI apps, dev toolchain, wayland wrappers, mimeApps
└── hosts/
    ├── sulla/                      Zen 3 + NVIDIA workstation, ZFS root, UPS, homelab
    ├── wsl/                        WSL2 dev box (Cursor IDE remote)
    └── laptop/                     placeholder for a future portable machine
```

## Hosts

- **Sulla** — AMD Zen 3, NVIDIA RTX (production driver, CUDA), ZFS rpool/bpool, mirrored EFI ESPs, sanoid + syncoid to rsync.net, NUT/UPS, Postgres, Jellyfin, UniFi controller, Plasma 6 desktop.
- **nixos-wsl** — NixOS-WSL on Windows. Carries the bash wrapper + nix-ld + `wsl.{wrapBinSh,extraBin}` block that Cursor IDE's remote server depends on. No desktop, no system services.
- **Laptop** — placeholder. Imports the desktop stack but is gated behind real hardware-configuration before it can build. Replace `networking.hostName` and `hardware-configuration.nix` after first install.

## Deploy

From the repo root on each machine (or via the `nrs` / `nrl` aliases that Home Manager installs):

```bash
sudo nixos-rebuild switch --flake ~/code/nixos#Sulla
sudo nixos-rebuild switch --flake ~/code/nixos#nixos-wsl
sudo nixos-rebuild switch --flake ~/code/nixos#Laptop
```

The `nrs` alias resolves the host automatically:

```bash
nrs   # = sudo nixos-rebuild switch --flake ~/code/nixos#$(hostname)
```

## Update inputs

```bash
nix flake update --flake ~/code/nixos
```

The lockfile is committed; `nix flake update` rewrites it with newer revisions of `nixpkgs`, `nixpkgs-stable` (currently `nixos-25.11`), `nixpkgs-staging`, `nixos-hardware`, `nixos-wsl`, and `home-manager`.

## Add a new host

1. `cp -r hosts/laptop hosts/<name>`
2. Replace `hardware-configuration.nix` with the output of `nixos-generate-config --show-hardware-config` from the live machine.
3. Set `networking.hostName`, the user's `extraGroups`, and any host-specific services in `hosts/<name>/default.nix`.
4. Add an entry to `nixosConfigurations` in [flake.nix](flake.nix), reusing the `mkHost` helper (`mkHost ./hosts/<name> [ ]`).
5. Pick the right Home Manager imports — desktop machines get `modules/home/desktop.nix` in addition to `modules/home/common.nix`; servers get `common.nix` only.
6. `sudo nixos-rebuild switch --flake ~/code/nixos#<name>`.

## Cursor IDE on the WSL host

Four things in [hosts/wsl/default.nix](hosts/wsl/default.nix) and [modules/nixos/common.nix](modules/nixos/common.nix) keep Cursor's WSL remote working. Do not remove any of them without a tested replacement:

1. `programs.nix-ld.enable = true` (in `modules/nixos/common.nix`) — Cursor ships a prebuilt Linux binary that requires a glibc-style dynamic linker.
2. `bashWrapper` derivation — prepends `gnugrep coreutils gnutar gzip getconf gnused procps which gawk wget curl util-linux` onto bash's PATH so Cursor's bootstrap scripts find them.
3. `wsl.wrapBinSh = true` — replaces `/bin/sh` with a NixOS-aware shell.
4. `wsl.extraBin = [ { name = "bash"; src = "${bashWrapper}/bin/bash"; } ]` — exposes the wrapped bash at `/bin/bash`.

## Configuration philosophy

- **Home Manager first.** If a setting only affects one user (shell, editor, dev tools, GUI apps, mime defaults), it belongs in `modules/home/*`.
- **NixOS modules only when forced.** Boot, kernel, drivers, system services, SUID programs, virtualisation, system users, `nixpkgs.overlays`, and the WSL bootstrap pieces are the only things that should grow `modules/nixos/*` or `hosts/*/default.nix`.
- **Rescue tools at root.** The system profile keeps `vim wget curl git nix-index` so a sudo recovery shell is functional even if a user's HM activation fails.
- **Per-host files stay small.** Hosts pull in modules and add only their hardware/role-specific options.
