# Body of the `update-antigravity` writeShellApplication in overlay.nix, which
# supplies the shebang, `set -euo pipefail`, the PATH, and runs ShellCheck.
#
#   Usage: nix run .#update-antigravity [-- path/to/sources.json]
#
# Asks Antigravity's update services for the latest hub and IDE releases,
# resolves every Linux platform's download hash, and rewrites sources.json.
# Run from the checkout root. Leaves the file untouched when both pins are
# current.

sources="${1:-overlays/antigravity/sources.json}"
[[ -f "$sources" ]] || {
  echo "error: $sources not found (run from the checkout root or pass the path)" >&2
  exit 1
}

data=$(cat "$sources")
changed=0

fetch() { curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 "$@"; }

# --- Antigravity (agent hub) -------------------------------------------------
# /releases lists {version, execution_id} newest first. Download URLs embed
# the execution ID next to the version. The updater manifest only carries a
# sha512 for the AppImage, so prefetch the tarballs.
hub_api="https://antigravity-hub-auto-updater-974169037036.us-central1.run.app"
hub_store="https://storage.googleapis.com/antigravity-public/antigravity-hub"

hub_release=$(fetch "$hub_api/releases" | jq -r '.[0] | "\(.version) \(.execution_id)"')
read -r hub_latest hub_build <<<"$hub_release"
[[ "$hub_latest" =~ ^[0-9.]+$ && "$hub_build" =~ ^[0-9]+$ ]] || {
  echo "error: unexpected hub release entry: $hub_release" >&2
  exit 1
}
hub_current=$(jq -r '.hub.version' <<<"$data")

if [[ "$hub_latest" == "$hub_current" ]]; then
  echo "hub: up to date ($hub_current)" >&2
else
  echo "hub: $hub_current -> $hub_latest" >&2
  hashes="{}"
  for pair in x86_64-linux:linux-x64 aarch64-linux:linux-arm; do
    IFS=: read -r sys platform <<<"$pair"
    url="$hub_store/$hub_latest-$hub_build/$platform/Antigravity.tar.gz"
    echo "  prefetching $url" >&2
    hash=$(nix --extra-experimental-features nix-command store prefetch-file --json "$url" | jq -r '.hash')
    hashes=$(jq --arg sys "$sys" --arg hash "$hash" '. + {($sys): $hash}' <<<"$hashes")
  done
  data=$(jq --arg v "$hub_latest" --arg b "$hub_build" --argjson h "$hashes" \
    '.hub = {version: $v, buildId: $b, hashes: $h}' <<<"$data")
  changed=1
fi

# --- Antigravity IDE -----------------------------------------------------------
# The update API has no version field; parse it from the download URL. It
# does publish the sha256, so no download is needed.
ide_api="https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/api/update"
ide_current=$(jq -r '.ide.version' <<<"$data")

ide_latest=""
ide_vscode=""
ide_sources="{}"
for pair in x86_64-linux:linux-x64 aarch64-linux:linux-arm64; do
  IFS=: read -r sys platform <<<"$pair"
  meta=$(fetch "$ide_api/$platform/stable/latest")
  url=$(jq -r '.url | gsub(" "; "%20")' <<<"$meta")
  vscode=$(jq -r '.productVersion' <<<"$meta")
  sha256=$(jq -r '.sha256hash' <<<"$meta")

  [[ "$url" =~ /stable/([0-9.]+)-[0-9]+/ ]] || {
    echo "error: cannot parse IDE version from $url" >&2
    exit 1
  }
  version="${BASH_REMATCH[1]}"

  if [[ -z "$ide_latest" ]]; then
    ide_latest=$version
    ide_vscode=$vscode
  elif [[ "$version" != "$ide_latest" || "$vscode" != "$ide_vscode" ]]; then
    echo "error: IDE $sys is at $version (vscode $vscode), expected $ide_latest (vscode $ide_vscode); retry later" >&2
    exit 1
  fi

  hash=$(nix-hash --type sha256 --to-sri "$sha256")
  ide_sources=$(jq --arg sys "$sys" --arg url "$url" --arg hash "$hash" \
    '. + {($sys): {url: $url, hash: $hash}}' <<<"$ide_sources")
done

if [[ "$ide_latest" == "$ide_current" ]]; then
  echo "ide: up to date ($ide_current)" >&2
else
  echo "ide: $ide_current -> $ide_latest (vscode $ide_vscode)" >&2
  data=$(jq --arg v "$ide_latest" --arg vs "$ide_vscode" --argjson s "$ide_sources" \
    '.ide = {version: $v, vscodeVersion: $vs, sources: $s}' <<<"$data")
  changed=1
fi

if ((changed)); then
  jq . <<<"$data" >"$sources"
  echo "Wrote $sources" >&2
fi
