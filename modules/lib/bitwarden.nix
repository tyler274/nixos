# Bitwarden CLI password helper and related firejail policy fragments.
{ pkgs, lib, item ? "libera.chat" }:
let
  bwBin = "${pkgs.bitwarden-cli}/bin/bw";
  jqBin = "${pkgs.jq}/bin/jq";
  readlinkBin = "${pkgs.coreutils}/bin/readlink";

  passwordScript = pkgs.runCommand "bitwarden-get-password-script" { } ''
    cat > $out <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
umask 077

expected_self=SCRIPT_PATH
expected_bw=BW_PATH

self=$(READLINK_PATH -f "$0")
if [[ "$self" != "$expected_self" ]]; then
  exit 1
fi

if [[ ! -x "$expected_bw" ]] || [[ "$(READLINK_PATH -f "$expected_bw")" != "$expected_bw" ]]; then
  exit 1
fi

export PATH=HELPER_PATH

item=ITEM_NAME
status_json=$("$expected_bw" status --raw 2>/dev/null || echo '{"status":"unauthenticated"}')
vault_status=$(JQ_PATH -r '.status // "unauthenticated"' <<< "$status_json")

if [[ "$vault_status" != "unlocked" ]]; then
  exit 1
fi

"$expected_bw" get password "$item" --nointeraction 2>/dev/null | tr -d '\n'
EOF

    ${pkgs.gnused}/bin/sed \
      -e "s|SCRIPT_PATH|$out|g" \
      -e "s|BW_PATH|${bwBin}|g" \
      -e "s|READLINK_PATH|${readlinkBin}|g" \
      -e "s|JQ_PATH|${jqBin}|g" \
      -e "s|HELPER_PATH|${lib.makeBinPath [
        pkgs.bitwarden-cli
        pkgs.jq
        pkgs.coreutils
      ]}|g" \
      -e "s|ITEM_NAME|${lib.escapeShellArg item}|g" \
      -i $out

    chmod 0555 $out
  '';

  # Lets sandboxed apps (e.g. Halloy under firejail) invoke the helper and bw.
  firejailLocal = ''
    ignore disable-shell.inc
    noblacklist ''${HOME}/.config/Bitwarden CLI
    noblacklist ''${HOME}/.config/Bitwarden
    read-only ${passwordScript}
    read-only ${bwBin}
  '';
in
{
  inherit passwordScript firejailLocal;
}
