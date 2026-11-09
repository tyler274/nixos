# Body of the `update-cursor` writeShellApplication in overlay.nix, which
# supplies the shebang, `set -euo pipefail`, the PATH, and runs ShellCheck.
#
#   Usage: nix run .#update-cursor [-- path/to/sources.json]
#
# Asks Cursor's update API for the latest stable release, prefetches every
# platform's download, and rewrites sources.json. Run from the checkout root.
# Prints "Already up to date" and changes nothing when the pin is current.

sources="${1:-overlays/code-cursor/sources.json}"
[[ -f "$sources" ]] || {
  echo "error: $sources not found (run from the checkout root or pass the path)" >&2
  exit 1
}

api="https://api2.cursor.sh/updates/api/download/stable"
latest=$(curl -fsSL "$api/linux-x64/cursor" | jq -r '.version')
current=$(jq -r '.version' "$sources")

[[ "$latest" == "$current" ]] && {
  echo "Already up to date ($current)"
  exit 0
}
echo "Updating Cursor $current -> $latest" >&2

entries="{}"
vscode=""
for pair in x86_64-linux:linux-x64 aarch64-linux:linux-arm64 aarch64-darwin:darwin-arm64; do
  IFS=: read -r sys platform <<<"$pair"
  meta=$(curl -fsSL "$api/$platform/cursor")
  version=$(jq -r '.version' <<<"$meta")
  [[ "$version" == "$latest" ]] || {
    echo "error: $sys is at $version, expected $latest; retry later" >&2
    exit 1
  }
  url=$(jq -r '.downloadUrl' <<<"$meta")

  echo "Prefetching $url" >&2
  { read -r hash; read -r path; } < <(nix-prefetch-url --print-path "$url")
  sri=$(nix-hash --type sha256 --to-sri "$hash")

  if [[ "$sys" == "x86_64-linux" ]]; then
    vscode=$(7zz x -so "$path" "usr/share/cursor/resources/app/product.json" 2>/dev/null | jq -r '.vscodeVersion')
  fi

  entries=$(jq -n --argjson e "$entries" --arg sys "$sys" --arg url "$url" --arg hash "$sri" \
    '$e + {($sys): {url: $url, hash: $hash}}')
done

jq -n --arg v "$latest" --arg vs "$vscode" --argjson s "$entries" \
  '{version: $v, vscodeVersion: $vs, sources: $s}' >"$sources"
echo "Wrote $sources ($latest, vscode $vscode)" >&2
