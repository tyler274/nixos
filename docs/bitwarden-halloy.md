# Bitwarden + Halloy (Libera IRC)

Halloy connects to Libera IRC with SASL PLAIN. The NickServ password lives in Bitwarden and is fetched at runtime by a hardened Nix store script — never written into `config.toml` or the Nix store as plaintext.

This document covers what is implemented, how to use it, and where work stopped on CLI ↔ desktop vault sharing.

## Goal

- Store the Libera NickServ password in Bitwarden (item name defaults to `libera.chat`).
- Halloy runs `password_command` when connecting; the script returns the password only when the **Bitwarden CLI vault is unlocked**.
- Keep server settings (including which command fetches the password) managed in Nix, with tamper detection on the generated Halloy config.

## Module layout

| File | Role |
|------|------|
| [`modules/lib/bitwarden.nix`](../modules/lib/bitwarden.nix) | Shared password helper script + firejail fragment |
| [`modules/home/bitwarden.nix`](../modules/home/bitwarden.nix) | Desktop + CLI packages, SSH agent socket, Libera item option |
| [`modules/home/halloy.nix`](../modules/home/halloy.nix) | Halloy Libera server config, config tamper protection |
| [`modules/nixos/bitwarden.nix`](../modules/nixos/bitwarden.nix) | Firejail `halloy.local` for sandboxed CLI access |

Enabled on desktop hosts via `modules/home/desktop.nix` and `modules/nixos/desktop-common.nix` (`bitwarden.enable = true`).

## How the password helper works

Script path: built by `bitwarden-get-password-script` in `modules/lib/bitwarden.nix`.

1. **Self-check** — Verifies its own path and that `bw` resolves to the pinned Nix store binary (guards against a swapped executable on `PATH`).
2. **Vault status** — Runs `bw status --raw` and reads `.status`.
3. **If not `unlocked`** — Exits **0 with no output**. Halloy loads `config.toml` at startup; a non-zero exit would fail the entire config load, so “no password yet” is silent.
4. **If `unlocked`** — Runs `bw get password <item> --nointeraction` and prints the password (newlines stripped).

Halloy invokes the command as:

```bash
bash /nix/store/...-bitwarden-get-password-script
```

The explicit `bash` wrapper is required because Halloy runs `password_command` via `sh -c`.

### Halloy config security

Home Manager would normally symlink `~/.config/halloy/config.toml` into the read-only Nix store. Two activations in `halloy.nix` work around that:

- **`prepareHalloyConfig`** (before `linkGeneration`) — Removes a previous read-only copy so HM can refresh the file.
- **`secureHalloyConfig`** (after `linkGeneration`) — Verifies `password_command` contains the expected Nix store script path, then replaces the symlink with a real file at mode `0444`.

If something edits `password_command` to point elsewhere, the next Home Manager switch fails.

### Firejail (Halloy sandbox)

`modules/nixos/bitwarden.nix` writes `/etc/firejail/halloy.local` so sandboxed Halloy can:

- Run a shell (`ignore disable-shell.inc`)
- Read `~/.config/Bitwarden CLI` and `~/.config/Bitwarden`
- Execute the read-only password script and `bw` binary

## One-time setup

1. **Rebuild** so modules are active:

   ```bash
   sudo nixos-rebuild switch --flake ~/code/nixos#Cyrene
   ```

2. **Log in to the CLI** (once per machine):

   ```bash
   bw login
   ```

   Desktop and CLI use **separate config directories**; logging into the desktop app does not log in the CLI.

3. **Create the Bitwarden login item** named `libera.chat` (or change `bitwarden.liberaItem` in Nix):
   - **Username**: your registered IRC nick (same as `config.home.username`, e.g. `luluco`)
   - **Password**: Libera NickServ password

4. **Unlock the CLI vault** before Halloy needs the password (see [Desktop vs CLI](#desktop-vs-cli-vault-state) below).

5. **Reload Halloy config** after unlocking — Halloy reads `password_command` output when loading config / connecting. If the vault was locked at config load, reload after unlock (Halloy: reload config, or restart the app).

## Daily workflow (current behavior)

1. Start Bitwarden Desktop and unlock the vault (optional for desktop use; **does not unlock CLI**).
2. Unlock the CLI: `bw unlock` (or export `BW_SESSION` from a prior unlock).
3. Open Halloy and connect to Libera — SASL uses the password from Bitwarden.

If the CLI vault stays locked, Halloy still starts but SASL will not receive a password until you unlock and reload.

## Desktop vs CLI vault state

**Unlocking Bitwarden Desktop does not unlock `bw`.** They are separate processes with separate state:

| | Desktop | CLI (`bw`) |
|---|---------|------------|
| Config dir | `~/.config/Bitwarden/` | `~/.config/Bitwarden CLI/` |
| Unlock | GUI master password / biometrics | `bw unlock` or `BW_SESSION` |
| Used by | Desktop app, browser extension (via integration) | Password helper, scripts, Halloy |

The password helper only checks **`bw status`**, not whether the desktop vault is unlocked.

### Official CLI (`apps/cli`)

The upstream CLI lives in the [Bitwarden clients monorepo](https://github.com/bitwarden/clients/tree/main/apps/cli). Nixpkgs `bitwarden-cli` packages this project.

On `main` today:

- [`CliBiometricsService`](https://github.com/bitwarden/clients/blob/main/apps/cli/src/key-management/cli-biometrics-service.ts) is a **stub** — always returns `PlatformUnsupported`; no desktop IPC.
- [`UnlockCommand`](https://github.com/bitwarden/clients/blob/main/apps/cli/src/key-management/commands/unlock.command.ts) only unlocks via **master password** and sets `BW_SESSION`.

Building from source does not add desktop integration.

### Closed upstream PR

Community [PR #18273](https://github.com/bitwarden/clients/pull/18273) implemented CLI biometric unlock via the same IPC channel browser extensions use (Unix socket to the desktop app). Bitwarden **closed it** (January 2026): they plan a new SDK-based IPC framework first, with no public timeline. The author’s work lives on as the standalone wrapper [**bwbio**](https://github.com/jeanregisser/bitwarden-cli-bio).

## Where we left off

### Done

- Modular Bitwarden + Halloy integration (see [Module layout](#module-layout)).
- Hardened password script with path pinning and self-check.
- Halloy `config.toml` tamper protection.
- Firejail policy for sandboxed Halloy → Bitwarden CLI.
- Documented limitation: desktop unlock ≠ CLI unlock.

### Not done (optional next steps)

| Option | Effort | Notes |
|--------|--------|-------|
| **Status quo** | None | User runs `bw unlock` when needed; reload Halloy config after unlock. |
| **`BW_SESSION` in session** | Low | Export session key after unlock; Halloy/firejail must see the env var (may need firejail whitelist). |
| **bwbio wrapper** | Medium | Package [bitwarden-cli-bio](https://github.com/jeanregisser/bitwarden-cli-bio) in Nix; update password script to call `bwbio unlock` when CLI is locked but desktop is running with browser integration enabled; extend firejail for desktop IPC socket under `$XDG_RUNTIME_DIR`. Still needs one-time `bw login`. May prompt Polkit on Linux. |
| **Wait for upstream** | Unknown | Official CLI desktop integration blocked on new IPC SDK ([contributing docs](https://contributing.bitwarden.com/architecture/deep-dives/ipc/)). |

No decision has been made yet between status quo and **bwbio**. Packaging `bwbio` was started in conversation but not merged into this repo.

### If implementing bwbio later

Rough checklist:

1. Add Nix package (e.g. `buildNpmPackage` from `jeanregisser/bitwarden-cli-bio`).
2. Add `bwbio` to `home.packages` in `modules/home/bitwarden.nix`.
3. Extend `modules/lib/bitwarden.nix` password script: if `bw status` ≠ `unlocked`, try `bwbio unlock --raw` (or equivalent) when desktop is available.
4. Extend `firejailLocal` for IPC socket access and any extra binaries (`node`, etc.).
5. Document desktop requirement: **Settings → Allow browser integration**, desktop unlocked.
6. Test under firejail: Halloy → password script → bwbio → desktop → password returned.

## Configuration options

```nix
# Home Manager (modules/home/bitwarden.nix)
bitwarden.enable = true;
bitwarden.liberaItem = "libera.chat";  # Bitwarden item name for bw get password

# NixOS (modules/nixos/bitwarden.nix)
bitwarden.halloy.firejail.enable = true;  # default; set false to drop halloy.local
```

Halloy Libera settings (in `modules/home/halloy.nix`): TLS, SASL plain, `disconnect_on_failure = true` (Libera recommendation — failed SASL disconnects instead of exposing real hostname).

## Related docs

- [Halloy — SASL PLAIN](https://halloy.chat/configuration/servers#sasl-plain)
- [Bitwarden CLI help](https://help.bitwarden.com/article/cli/)
- [Bitwarden CLI source (`apps/cli`)](https://github.com/bitwarden/clients/tree/main/apps/cli)
