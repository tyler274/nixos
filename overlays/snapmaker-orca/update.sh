# Body of the `snapmaker-orca-update` writeShellApplication in overlay.nix,
# which supplies the shebang, `set -euo pipefail`, the PATH, and runs
# ShellCheck during the derivation build. Not runnable standalone.
#
#   Usage: snapmaker-orca-update [path/to/package.nix]
#
# Queries GitHub for the latest Snapmaker/OrcaSlicer release, picks the
# Ubuntu 24.04 x86_64 AppImage, prefetches it to compute the SRI hash, and
# rewrites version / url / hash in package.nix in place. The package path
# defaults to overlays/snapmaker-orca/package.nix relative to the current
# directory (run from the root of this checkout). Safe to re-run: when the
# pin already matches latest it prints "already up to date" and changes
# nothing.

api_url="https://api.github.com/repos/Snapmaker/OrcaSlicer/releases/latest"
pkg="${1:-overlays/snapmaker-orca/package.nix}"

die() {
  echo "error: $*" >&2
  exit 1
}

[ -f "$pkg" ] ||
  die "package not found: $pkg
usage: snapmaker-orca-update [path/to/package.nix]
(run from the root of the nixos config checkout, or pass the path explicitly)"

echo "Fetching $api_url ..." >&2
json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api_url")" ||
  die "failed to fetch $api_url"

jq -e '.tag_name and (.assets | type == "array")' <<<"$json" >/dev/null ||
  die "unexpected GitHub response (want .tag_name and .assets array): $(head -c 300 <<<"$json")"

tag="$(jq -r '.tag_name' <<<"$json")"
new_version="${tag#[vV]}"
[ -n "$new_version" ] || die "empty version parsed from tag_name=$tag"

# Prefer the Ubuntu 24.04 x86_64 AppImage; skip flatpak / aarch64 / Windows.
mapfile -t assets < <(jq -r '
  .assets[]
  | select(.name | test("Linux_AppImage.*\\.AppImage$"))
  | select(.name | test("aarch64|arm64") | not)
  | "\(.name)\t\(.browser_download_url)"
' <<<"$json")

[ "${#assets[@]}" -gt 0 ] ||
  die "no Linux x86_64 AppImage on $tag; assets: $(jq -r '.assets[].name' <<<"$json" | tr '\n' ' ')"

new_url=""
new_name=""
for row in "${assets[@]}"; do
  name="${row%%$'\t'*}"
  url="${row#*$'\t'}"
  if [[ "$name" == *Ubuntu2404* ]]; then
    new_name="$name"
    new_url="$url"
    break
  fi
done
if [ -z "$new_url" ]; then
  new_name="${assets[0]%%$'\t'*}"
  new_url="${assets[0]#*$'\t'}"
fi

echo "Latest upstream release: $tag ($new_version)" >&2
echo "  $new_name" >&2
echo "  $new_url" >&2

old_version="$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$pkg")"
old_url="$(sed -n 's/^    url = "\(.*\)";$/\1/p' "$pkg")"
old_hash="$(sed -n 's/^    hash = "\(sha256-.*\)";$/\1/p' "$pkg")"
for var in old_version old_url old_hash; do
  [ -n "${!var}" ] || die "could not parse ${var#old_} out of $pkg (formatting changed?)"
done

old_url_expanded="${old_url//\$\{version\}/$old_version}"

if [ "$new_version" = "$old_version" ] && [ "$new_url" = "$old_url_expanded" ]; then
  echo "already up to date ($old_version)"
  exit 0
fi

echo "Prefetching AppImage to compute the SRI hash ..." >&2
new_hash="$(nix --extra-experimental-features 'nix-command flakes' \
  store prefetch-file --json --name "$new_name" "$new_url" | jq -r .hash)"
[[ "$new_hash" == sha256-* ]] || die "prefetch did not yield an sha256 SRI hash: $new_hash"

# Keep ${version} interpolation when the URL is the usual
# .../download/V<ver>/Snapmaker_Orca_Linux_AppImage_Ubuntu2404_V<ver>.AppImage
# (capital V in both the tag and the filename).
suffix="Snapmaker_Orca_Linux_AppImage_Ubuntu2404_V${new_version}.AppImage"
if [[ "$new_url" == "https://github.com/Snapmaker/OrcaSlicer/releases/download/V${new_version}/$suffix" ]]; then
  # shellcheck disable=SC2016 # ${version} is a literal Nix interpolation
  new_url_nix='https://github.com/Snapmaker/OrcaSlicer/releases/download/V${version}/Snapmaker_Orca_Linux_AppImage_Ubuntu2404_V${version}.AppImage'
else
  new_url_nix="$new_url"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
awk -v ver="$new_version" -v url="$new_url_nix" -v hash="$new_hash" '
  /^  version = ".*";$/       { print "  version = \"" ver "\";"; next }
  /^    url = ".*";$/         { print "    url = \"" url "\";"; next }
  /^    hash = "sha256-.*";$/ { print "    hash = \"" hash "\";"; next }
  { print }
' "$pkg" >"$tmp"
cat "$tmp" >"$pkg"

if ! grep -qF "version = \"$new_version\";" "$pkg" ||
  ! grep -qF "url = \"$new_url_nix\";" "$pkg" ||
  ! grep -qF "hash = \"$new_hash\";" "$pkg"; then
  die "rewrite failed; $pkg left in an inconsistent state, check git diff"
fi

echo "Updated $pkg:"
echo "  version: $old_version -> $new_version"
echo "  url:     $old_url_expanded"
echo "        -> $new_url"
echo "  hash:    $old_hash -> $new_hash"
