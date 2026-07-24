# Body of the `xtool-studio-update` writeShellApplication in ./default.nix,
# which supplies the shebang, `set -euo pipefail`, the PATH (curl, jq, nix,
# awk/sed/grep/coreutils), and runs shellcheck at build time. Not runnable
# standalone.
#
#   Usage: xtool-studio-update [path/to/default.nix]
#
# Queries xTool's version API for the latest Windows x64 installer, prefetches
# it into the nix store to compute the SRI hash (~750 MB download), and
# rewrites version / url / hash in the module in place. The module path
# defaults to modules/nixos/xtool-studio/default.nix relative to the current
# directory, i.e. run it from the root of a checkout of this repo. Safe to
# re-run: when the module already pins the latest release it prints
# "already up to date" and changes nothing.

api_url="https://api.xtool.com/efficacy/v1/data/type/atomm_studio_version/items"
module="${1:-modules/nixos/xtool-studio/default.nix}"

die() {
  echo "error: $*" >&2
  exit 1
}

[ -f "$module" ] ||
  die "module not found: $module
usage: xtool-studio-update [path/to/default.nix]
(run from the root of the nixos config checkout, or pass the path explicitly)"

echo "Fetching $api_url ..." >&2
json="$(curl -fsSL "$api_url")" || die "failed to fetch $api_url"

# API shape (as of 2026-07):
#   { "code": 0, "message": "",
#     "data": [ { "code": "xtool_win" | "xtool_macos" | "xtool_macos_arm",
#                 "status": "enabled",
#                 "extra": { "package_url": "https://storage.atomm.com/...
#                              .../<uuid>/xTool-Studio-x64-<version>.exe",
#                            "version": "1.7" } }, ... ] }
# NB: extra.version is truncated (major.minor only) — the full version exists
# only in the package_url filename, so it is parsed out of that.
jq -e '.code == 0 and (.data | type == "array")' <<<"$json" >/dev/null ||
  die "unexpected API response shape (want .code==0 and .data array): $(head -c 300 <<<"$json")"

# All enabled Windows x64 .exe package URLs.
mapfile -t urls < <(jq -r '
  .data[]
  | select(.code == "xtool_win" and .status == "enabled")
  | .extra.package_url // empty
  | select(test("/xTool-Studio-x64-[0-9]+(\\.[0-9]+)*\\.exe$"))
' <<<"$json")

[ "${#urls[@]}" -gt 0 ] ||
  die "no enabled Windows x64 installer entry found; API shape changed? Raw response: $(head -c 300 <<<"$json")"

# Pick the newest by the version embedded in the filename.
new_url="" new_version=""
for u in "${urls[@]}"; do
  v="${u##*/xTool-Studio-x64-}"
  v="${v%.exe}"
  if [ -z "$new_version" ] || [ "$(printf '%s\n%s\n' "$new_version" "$v" | sort -V | tail -n1)" = "$v" ]; then
    new_version="$v"
    new_url="$u"
  fi
done

echo "Latest upstream release: $new_version" >&2
echo "  $new_url" >&2

# Current pins in default.nix. The patterns are anchored to the exact
# indentation used there so nothing else in the file can match.
old_version="$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$module")"
old_url="$(sed -n 's/^    url = "\(.*\)";$/\1/p' "$module")"
old_hash="$(sed -n 's/^    hash = "\(sha256-.*\)";$/\1/p' "$module")"
for var in old_version old_url old_hash; do
  [ -n "${!var}" ] || die "could not parse ${var#old_} out of $module (formatting changed?)"
done

# The module's url embeds ${version}; expand it for comparison with the API's.
old_url_expanded="${old_url//\$\{version\}/$old_version}"

if [ "$new_version" = "$old_version" ] && [ "$new_url" = "$old_url_expanded" ]; then
  echo "already up to date ($old_version)"
  exit 0
fi

echo "Prefetching installer (~750 MB) to compute the SRI hash ..." >&2
new_hash="$(nix --extra-experimental-features 'nix-command flakes' \
  store prefetch-file --json "$new_url" | jq -r .hash)"
[[ "$new_hash" == sha256-* ]] || die "prefetch did not yield an sha256 SRI hash: $new_hash"

# Keep the ${version} interpolation in the module when the URL ends in the
# usual xTool-Studio-x64-<version>.exe pattern; otherwise write it literally.
suffix="xTool-Studio-x64-$new_version.exe"
if [[ "$new_url" == *"/$suffix" ]]; then
  # shellcheck disable=SC2016 # ${version} is a literal Nix interpolation
  new_url_nix="${new_url%"$suffix"}"'xTool-Studio-x64-${version}.exe'
else
  new_url_nix="$new_url"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
awk -v ver="$new_version" -v url="$new_url_nix" -v hash="$new_hash" '
  /^  version = ".*";$/         { print "  version = \"" ver "\";"; next }
  /^    url = ".*";$/           { print "    url = \"" url "\";"; next }
  /^    hash = "sha256-.*";$/   { print "    hash = \"" hash "\";"; next }
  { print }
' "$module" >"$tmp"
cat "$tmp" >"$module" # cat-into keeps the file's permissions/inode

# Verify the rewrite took.
if ! grep -qF "version = \"$new_version\";" "$module" ||
  ! grep -qF "url = \"$new_url_nix\";" "$module" ||
  ! grep -qF "hash = \"$new_hash\";" "$module"; then
  die "rewrite failed; $module left in an inconsistent state, check git diff"
fi

echo "Updated $module:"
echo "  version: $old_version -> $new_version"
echo "  url:     $old_url_expanded"
echo "        -> $new_url"
echo "  hash:    $old_hash -> $new_hash"
