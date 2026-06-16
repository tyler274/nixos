# nixos

Multi-host NixOS flake for Tyler's machines. Home Manager is the primary configuration surface for anything user-facing; the NixOS modules are kept as small as possible and only carry things that genuinely need root (boot, kernel, hardware, system services, SUID wrappers, system users).

## Layout

```
.
├── flake.nix                       root flake: inputs, overlays, mkHost helper, nixosConfigurations
├── flake.lock                      pinned input revisions (committed)
├── modules/
│   ├── nixos/                      system-level modules (root-only concerns)
│   │   ├── common.nix              nix settings + GC, locale, nix-ld, sshd, postgres, jellyfin,
│   │   │                           NUT/UPS, docker/incus/lxc/waydroid, HM wiring, kernel blacklist
│   │   ├── desktop-common.nix      Plasma 6 (SDDM/Wayland), pipewire, bluetooth, printing/scanning,
│   │   │                           firejail wrappers, steam, xdg portals, apparmor, fonts
│   │   ├── bitwarden.nix           firejail halloy.local for Bitwarden CLI in sandboxed Halloy
│   │   ├── amd.nix                 AMD microcode, kvm-amd, amd_pstate (EPP), power-profiles-daemon
│   │   ├── nvidia.nix              proprietary NVIDIA driver, CUDA, container toolkit, color-pipeline fix
│   │   ├── cuda.nix                WSL CUDA + docker NVIDIA runtime (uses the Windows-side driver)
│   │   ├── ccache.nix              ccache wrapper + sandbox path, hardened cache-dir checks
│   │   ├── mold.nix                overlay that links ccache.packageNames with the mold linker
│   │   ├── zfs-home.nix            custom `zfsHome` option: per-user ZFS home datasets + mounts
│   │   ├── kwin-git.nix            overlay that patches kdePackages.kwin
│   │   └── kwin-patches/           patch files consumed by kwin-git.nix
│   ├── lib/
│   │   └── bitwarden.nix           hardened bw password helper + firejail fragments (Halloy/Libera)
│   └── home/                       Home Manager modules (per-user surface)
│       ├── common.nix              bash, git, ssh, direnv, starship, htop, nixd/nixfmt, CLI tools, xdg
│       ├── bitwarden.nix           Bitwarden desktop + CLI, SSH agent, Libera item option
│       ├── halloy.nix              Halloy + Libera SASL via Bitwarden password_command
│       ├── desktop.nix             GUI apps, dev toolchain, wayland wrappers, mimeApps
│       └── plasma.nix              plasma-manager: look & feel, kwin, screen locker, panels, konsole
└── hosts/
    ├── cyrene/                     Zen 4 + RTX 4090 workstation, ZFS root, UPS, homelab
    │   ├── default.nix             full workstation config
    │   ├── minimal.nix             bootstrap config (CyreneMinimal) — install, boot, then switch
    │   ├── zfs.nix                 rpool (encrypted), lanzaboote, sanoid/syncoid, scrub/trim
    │   └── hardware-configuration.nix
    ├── wsl/                        WSL2 dev box (hostname `eula`, Cursor IDE remote)
    ├── laptop/                     placeholder for a future portable machine
    ├── phainon/                    work in progress — not yet wired into flake.nix
    └── sulla/                      work in progress — not yet wired into flake.nix
```

## Hosts

The flake exposes these `nixosConfigurations` (the attribute name is the deploy target):

- **Cyrene** (`./hosts/cyrene`) — AMD Zen 4, NVIDIA RTX 4090 (latest driver, CUDA), encrypted ZFS rpool with lanzaboote Secure Boot, sanoid + syncoid to rsync.net and a local-backup pool, NUT/UPS, Postgres, Jellyfin, full Plasma 6 desktop. Adds the `lanzaboote` module.
- **CyreneMinimal** (`./hosts/cyrene/minimal.nix`) — same hardware, stripped bootstrap config (SSH + ZFS home only). Install this first, boot in, then `nixos-rebuild switch` to the full `Cyrene`.
- **eula** (`./hosts/wsl`) — NixOS-WSL on Windows. Carries the bash wrapper + nix-ld + `wsl.{wrapBinSh,extraBin}` block that Cursor IDE's remote server depends on, plus `cuda.nix` for GPU passthrough. No desktop, no system services.
- **Laptop** (`./hosts/laptop`) — placeholder. Imports the desktop stack but is gated behind a real `hardware-configuration.nix` before it can build. Replace `networking.hostName` and the hardware config after first install.

`hosts/phainon` and `hosts/sulla` exist but are **not** referenced in `flake.nix` yet (see Known rough edges).

## Deploy

From the repo root on each machine (or via the `nrs` / `nrl` aliases that Home Manager installs):

```bash
sudo nixos-rebuild switch --flake ~/code/nixos#Cyrene
sudo nixos-rebuild switch --flake ~/code/nixos#eula
sudo nixos-rebuild switch --flake ~/code/nixos#Laptop
```

The `nrs` alias resolves the host automatically from the hostname:

```bash
nrs   # = sudo nixos-rebuild switch --flake ~/code/nixos#$(hostname)
```

(`nrl` is the same without the `#host` suffix, and `nfu` runs `nix flake update`.)

## Update inputs

```bash
nix flake update --flake ~/code/nixos
```

The lockfile is committed. The flake's inputs are `nixpkgs` (`nixos-unstable`, the primary tree), `nixpkgs-stable` (`nixos-26.05`) and `nixpkgs-staging` (both exposed to packages as `stable-pkgs` / `staging-pkgs` via an overlay), `nixos-hardware`, `nixos-wsl`, `home-manager` (`master`), `lanzaboote`, `aagl` (anime game launchers), `kwin-src`, and `plasma-manager`.

## Add a new host

1. `cp -r hosts/laptop hosts/<name>`
2. Replace `hardware-configuration.nix` with the output of `nixos-generate-config --show-hardware-config` from the live machine.
3. Set `networking.hostName`, the user's `extraGroups`, and any host-specific services in `hosts/<name>/default.nix`.
4. Add an entry to `nixosConfigurations` in [flake.nix](flake.nix), reusing the `mkHost` helper (`mkHost ./hosts/<name> [ ]`; pass extra NixOS modules like `lanzaboote.nixosModules.lanzaboote` in the list).
5. Pick the right Home Manager imports — desktop machines get `modules/home/desktop.nix` and `modules/home/plasma.nix` on top of `modules/home/common.nix`; servers/WSL get `common.nix` only.
6. `sudo nixos-rebuild switch --flake ~/code/nixos#<name>`.

## Cursor IDE on the WSL host

Four things in [hosts/wsl/default.nix](hosts/wsl/default.nix) and [modules/nixos/common.nix](modules/nixos/common.nix) keep Cursor's WSL remote working. Do not remove any of them without a tested replacement:

1. `programs.nix-ld.enable = true` (in `modules/nixos/common.nix`) — Cursor ships a prebuilt Linux binary that requires a glibc-style dynamic linker.
2. `bashWrapper` derivation — prepends `gnugrep coreutils gnutar gzip getconf gnused procps which gawk wget curl util-linux` onto bash's PATH so Cursor's bootstrap scripts find them.
3. `wsl.wrapBinSh = true` — replaces `/bin/sh` with a NixOS-aware shell.
4. `wsl.extraBin = [ { name = "bash"; src = "${bashWrapper}/bin/bash"; } ]` — exposes the wrapped bash at `/bin/bash`.

## Editor tooling

[.vscode/settings.json](.vscode/settings.json) points the Nix IDE extension at the `nixd` language server (installed via `modules/home/common.nix`) with `nixfmt` format-on-save, so Cursor/VS Code get LSP and formatting on any host that imports the home module.

## Bitwarden + Halloy

Libera IRC SASL passwords are fetched from Bitwarden at runtime (not stored in the Nix store). Desktop unlock does **not** unlock the CLI — see [docs/bitwarden-halloy.md](docs/bitwarden-halloy.md) for setup, security model, upstream CLI status, and open work (e.g. optional **bwbio** integration).

## Configuration philosophy

- **Home Manager first.** If a setting only affects one user (shell, editor, dev tools, GUI apps, mime defaults, Plasma), it belongs in `modules/home/*`.
- **NixOS modules only when forced.** Boot, kernel, drivers, system services, SUID programs, virtualisation, system users, `nixpkgs.overlays`, and the WSL bootstrap pieces are the only things that should grow `modules/nixos/*` or `hosts/*/default.nix`.
- **Rescue tools at root.** The system profile keeps `vim wget curl git nix-index` so a sudo recovery shell is functional even if a user's HM activation fails.
- **Per-host files stay small.** Hosts pull in modules and add only their hardware/role-specific options.

## Known rough edges

- `hosts/phainon` and `hosts/sulla` are not yet in `flake.nix`, so they don't build via `nixos-rebuild`. `hosts/phainon/default.nix` also sets `networking.hostName = "Sulla"`, and `hosts/sulla/` currently only has a (partly corrupted) `zfs.nix` with no `default.nix`.
- Cyrene, phainon, and sulla currently share the ZFS `networking.hostId` lineage; Cyrene has since been given a unique id (`69e5e3ea`).
