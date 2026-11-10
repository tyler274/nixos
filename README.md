# nixos

Multi-host NixOS flake for Tyler's machines. Home Manager is the primary configuration surface for anything user-facing; the NixOS modules are kept as small as possible and only carry things that genuinely need root (boot, kernel, hardware, system services, SUID wrappers, system users).

## Layout

```
.
├── flake.nix                       root flake: inputs, overlays, mkHost helper, nixosConfigurations
├── flake.lock                      pinned input revisions (committed)
├── overlays/                       package overrides (znver5, CUDA, allocators, ElyLD, rustc ElyMalloc)
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
│   │   ├── wild.nix                Cyrene: stdenv + clangStdenv use ElyLD from github:tyler274/ElyLD
│   │   ├── rustc-elymalloc.nix     Cyrene: rustc + rustPlatform use ElyMalloc instead of jemalloc
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
│       ├── hermes-agent.nix        Cyrene: Hermes Agent (Nous Research) gateway + dashboard user services
│       └── plasma.nix              plasma-manager: look & feel, kwin, screen locker, panels, konsole
└── hosts/
    ├── cyrene/                     Zen 4 + RTX 4090 workstation, ZFS root, UPS, homelab
    │   ├── default.nix             full workstation config
    │   ├── minimal.nix             bootstrap config (CyreneMinimal) - install, boot, then switch
    │   ├── zfs.nix                 rpool (encrypted), lanzaboote, sanoid/syncoid, scrub/trim
    │   └── hardware-configuration.nix
    ├── wsl/                        WSL2 dev box (hostname `eula`, Cursor IDE remote)
    ├── laptop/                     placeholder for a future portable machine
    ├── phainon/                    work in progress - not yet wired into flake.nix
    ├── sulla/                      work in progress - not yet wired into flake.nix
    └── macbook/                    macOS: user nix.conf + Home Manager (mcp-nixos)
```

## Hosts

The flake exposes these `nixosConfigurations` (the attribute name is the deploy target):

- **Cyrene** (`./hosts/cyrene`) - AMD Zen 5 (znver5), NVIDIA RTX 4090 (latest driver, CUDA), encrypted ZFS rpool with lanzaboote Secure Boot, sanoid + syncoid to rsync.net and a local-backup pool, NUT/UPS, Postgres, Jellyfin, full Plasma 6 desktop. stdenv linker is ElyLD (`github:tyler274/ElyLD`); glibc malloc is ElyMalloc (`environment.memoryAllocator.provider = "elymalloc"`). rustc is rebuilt without jemalloc; ElyMalloc is compiled into libstd (static `malloc` override, same model as rustc's jemalloc-sys) so Nix-built Rust programs embed it. Adds the `lanzaboote` module.
- **CyreneMinimal** (`./hosts/cyrene/minimal.nix`) - same hardware, stripped bootstrap config (SSH + ZFS home only). Install this first, boot in, then `nixos-rebuild switch` to the full `Cyrene`.
- **eula** (`./hosts/wsl`) - NixOS-WSL on Windows. Carries the bash wrapper + nix-ld + `wsl.{wrapBinSh,extraBin}` block that Cursor IDE's remote server depends on, plus `cuda.nix` for GPU passthrough. No desktop, no system services.
- **Laptop** (`./hosts/laptop`) - placeholder. Imports the desktop stack but is gated behind a real `hardware-configuration.nix` before it can build. Replace `networking.hostName` and the hardware config after first install.

`hosts/phainon` and `hosts/sulla` exist but are **not** referenced in `flake.nix` yet (see Known rough edges).

**macbook** (`./hosts/macbook`) is this Mac, not a NixOS host. `nix.conf` enables flakes for the user client. `home.nix` is a Home Manager configuration that installs `pkgs.mcp-nixos` (the declarative nixpkgs package) and writes `~/.cursor/mcp.json` so Cursor starts that binary.

```bash
mkdir -p ~/.config/nix
ln -sfn ~/code/nixos/hosts/macbook/nix.conf ~/.config/nix/nix.conf
nix run home-manager -- switch --flake ~/code/nixos#macbook
```

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

## Coda agent sandbox on Cyrene

Coding agents work on `coda-rust` inside `coda-agent`, a NixOS container defined in [hosts/cyrene/agent-container.nix](hosts/cyrene/agent-container.nix) on the module [modules/nixos/agent-sandbox.nix](modules/nixos/agent-sandbox.nix). The container has its own user namespace (the agent is host UID 656360), a private network that cannot reach the host, the LAN or Tailscale, no sudo and no Docker. It sees only these host paths:

| Container path | Host path | Access |
| --- | --- | --- |
| `/agents/coda/src` | dataset `agents/coda/src` (hourly snapshots) | read-write |
| `/agents/coda/build` | dataset `agents/coda/build` (no snapshots) | read-write |
| `/agents/coda/ci/requests` | `/agents/coda/ci/spool/requests` | read-write |
| `/agents/coda/ci/results` | `/agents/coda/ci/spool/results` | read-only |
| `/agents/coda/carry` | `/var/lib/coda-carry` | read-only |
| `/run/agent-secrets` | `/var/lib/agent-secrets/coda-agent` | read-only |
| `/nix/store`, daemon socket | host store | read-only; the agent is an untrusted daemon user |

Paths equal the host's so the host Nix daemon's GC roots for each worktree's dev shell stay valid. The pool is imported after boot by `agents-pool.service` ([hosts/cyrene/zfs/agents.nix](hosts/cyrene/zfs/agents.nix)); if the disk or key is missing, only that unit and the container fail. `nix build .#checks.x86_64-linux.agent-sandbox -L` runs the container definition in a throwaway VM and checks the boundaries.

Host git refuses trees the agent wrote (they belong to another UID). Do not mark them `safe.directory`: a hook or config the agent planted would run as you. Work on them from inside the container, or bring work out as a bundle.

### Agent sandbox credentials

The agent's tokens are files the agent can read and not change. Create a fine-grained GitHub token limited to `Coda-Health/coda-rust` with **Contents: read and write** and **Pull requests: read and write**, and a Doppler service token for the `dev` config (read-only). Then:

```bash
d=/var/lib/agent-secrets/coda-agent
sudo install -m 0440 -o root -g 655460 /dev/stdin $d/github-token   # paste, then Ctrl-D
sudo install -m 0440 -o root -g 655460 /dev/stdin $d/doppler-token  # paste, then Ctrl-D
```

Inside, git uses the GitHub token over HTTPS (remotes written as `git@github.com:` are rewritten), and `GH_TOKEN` and `DOPPLER_TOKEN` are set for login shells. Revoking either token on GitHub or Doppler is the kill switch.

### Working in the sandbox from Cursor

Connect with Remote-SSH to host `coda-agent` (the entry in [modules/home/common.nix](modules/home/common.nix) uses the dedicated key `~/.ssh/coda-agent`, with agent forwarding off) and open `/agents/coda/src/coda-rust`. Keep these Cursor settings off so no host credential is forwarded: `remote.SSH.enableAgentForwarding`, `git.terminalAuthentication`, `github.gitAuthentication`. `coda-rust`'s `dev/worktree.sh` owns worktrees and their build directories there.

### Bringing host worktrees over

`sudo coda-carry` records every host worktree of `~/code/coda/coda-rust` as refs, publishing nothing: `refs/carry/<slug>/head` for its commit and `refs/carry/<slug>/dirty` for a snapshot of uncommitted and untracked files, built with a temporary index so the worktree is untouched. It writes one bundle to `/var/lib/coda-carry/` and lists ignored files outside `target/` beside it. Inside the container, `git fetch /agents/coda/carry/carry.bundle 'refs/carry/*:refs/carry/*'` makes all of it available to `dev/worktree.sh new <slug> --from carry/<slug>/dirty`.
## Enable isolated Coda qualification

The runner module defaults to disabled. It registers disposable JIT runners only for `Coda-Health/coda-rust`, using the repository runner API and its default runner group ID `1`; no organization runner group setup is required. Run-attempt labels route jobs, but labels are not workflow authorization: other workflows in this repository can target the runner. There is no organization-level selected-workflow restriction.

Create the repository environment `cyrene-approval` with required reviewers, prevention of self-review, no administrator bypass, and a custom branch policy allowing only the `main` branch. The controller verifies these settings before registering a runner. These safeguards protect the qualification workflow, not other repository workflows that omit this environment.

Provision the controller's GitHub token through Doppler to a root-only runtime file. Scope the token to `Coda-Health/coda-rust` with repository **Administration: write**, **Actions: read**, and **Environments: read** permissions. Set `services.coda-ci.tokenFile` to that file and `services.coda-ci.enable = true`. Review and authorize host activation separately. The token is passed as a systemd credential and never enters the guest.

Dispatch `Cyrene qualification` on `main` with the full commit SHA. Review that SHA before approving the environment. Each run attempt gets a unique runner label and private cache image. No PR cache is reused by local builds or another run attempt. The controller allows one 16 GiB guest only when at least 24 GiB of host memory is available. CI cache files older than seven days are pruned, and the controller refuses new work above its 100 GiB allocated-cache budget.

Before allowing real PR code, qualify guest boot, checkout, denied host and LAN access, cancellation, controller termination, and post-reboot reconciliation. `ephemeral` registration alone is not evidence of VM isolation. Required Blacksmith CI remains independent. Stop the timer and service before disabling or rolling back this module. Do not remove cache data as part of rollback.

## Update inputs

```bash
nix flake update --flake ~/code/nixos
```

The lockfile is committed. The flake's inputs are `nixpkgs` (`nixos-unstable`, the primary tree), `nixpkgs-stable` (`nixos-26.05`) and `nixpkgs-staging` (both exposed to packages as `stable-pkgs` / `staging-pkgs` via an overlay), `nixos-hardware`, `nixos-wsl`, `home-manager` (`master`), `lanzaboote`, `aagl` (anime game launchers), `kwin-src`, `plasma-manager`, `elymalloc` (`github:tyler274/ElyMalloc`), and `elyld` (`github:tyler274/ElyLD`).

## Add a new host

1. `cp -r hosts/laptop hosts/<name>`
2. Replace `hardware-configuration.nix` with the output of `nixos-generate-config --show-hardware-config` from the live machine.
3. Set `networking.hostName`, the user's `extraGroups`, and any host-specific services in `hosts/<name>/default.nix`.
4. Add an entry to `nixosConfigurations` in [flake.nix](flake.nix), reusing the `mkHost` helper (`mkHost ./hosts/<name> [ ]`; pass extra NixOS modules like `lanzaboote.nixosModules.lanzaboote` in the list).
5. Pick the right Home Manager imports - desktop machines get `modules/home/desktop.nix` and `modules/home/plasma.nix` on top of `modules/home/common.nix`; servers/WSL get `common.nix` only.
6. `sudo nixos-rebuild switch --flake ~/code/nixos#<name>`.

## Cursor IDE on the WSL host

Four things in [hosts/wsl/default.nix](hosts/wsl/default.nix) and [modules/nixos/common.nix](modules/nixos/common.nix) keep Cursor's WSL remote working. Do not remove any of them without a tested replacement:

1. `programs.nix-ld.enable = true` (in `modules/nixos/common.nix`) - Cursor ships a prebuilt Linux binary that requires a glibc-style dynamic linker.
2. `bashWrapper` derivation - prepends `gnugrep coreutils gnutar gzip getconf gnused procps which gawk wget curl util-linux` onto bash's PATH so Cursor's bootstrap scripts find them.
3. `wsl.wrapBinSh = true` - replaces `/bin/sh` with a NixOS-aware shell.
4. `wsl.extraBin = [ { name = "bash"; src = "${bashWrapper}/bin/bash"; } ]` - exposes the wrapped bash at `/bin/bash`.

## Editor tooling

[.vscode/settings.json](.vscode/settings.json) points the Nix IDE extension at the `nixd` language server (installed via `modules/home/common.nix`) with `nixfmt` format-on-save, so Cursor/VS Code get LSP and formatting on any host that imports the home module.

## Bitwarden + Halloy

Libera IRC SASL passwords are fetched from Bitwarden at runtime (not stored in the Nix store). Desktop unlock does **not** unlock the CLI - see [docs/bitwarden-halloy.md](docs/bitwarden-halloy.md) for setup, security model, upstream CLI status, and open work (e.g. optional **bwbio** integration).

## Configuration philosophy

- **Home Manager first.** If a setting only affects one user (shell, editor, dev tools, GUI apps, mime defaults, Plasma), it belongs in `modules/home/*`.
- **NixOS modules only when forced.** Boot, kernel, drivers, system services, SUID programs, virtualisation, system users, `nixpkgs.overlays`, and the WSL bootstrap pieces are the only things that should grow `modules/nixos/*` or `hosts/*/default.nix`.
- **Rescue tools at root.** The system profile keeps `vim wget curl git nix-index` so a sudo recovery shell is functional even if a user's HM activation fails.
- **Per-host files stay small.** Hosts pull in modules and add only their hardware/role-specific options.

## Known rough edges

- `hosts/phainon` and `hosts/sulla` are not yet in `flake.nix`, so they don't build via `nixos-rebuild`. `hosts/phainon/default.nix` also sets `networking.hostName = "Sulla"`, and `hosts/sulla/` currently only has a (partly corrupted) `zfs.nix` with no `default.nix`.
- Cyrene, phainon, and sulla currently share the ZFS `networking.hostId` lineage; Cyrene has since been given a unique id (`69e5e3ea`).
