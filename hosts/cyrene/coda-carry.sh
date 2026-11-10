# coda-carry: record every host worktree of coda-rust as refs and bundle them
# for the coda-agent sandbox. Run as `sudo coda-carry`.
#
# All git runs as the repository's owner (CODA_CARRY_USER), never as root, so
# no hook or config in the trees runs with privilege; root only installs the
# finished files into CODA_CARRY_OUT, which the sandbox binds read-only.
#
#   refs/carry/<slug>/head   the worktree's HEAD
#   refs/carry/<slug>/dirty  HEAD plus uncommitted and untracked changes,
#                            built with a temporary index; the worktree,
#                            its index and its stash are untouched
#   carry.bundle             all refs/carry refs
#   ignored.txt              ignored files outside target/, per worktree
repo=${CODA_CARRY_REPO:-/home/luluco/code/coda/coda-rust}
out=${CODA_CARRY_OUT:-/var/lib/coda-carry}
user=${CODA_CARRY_USER:-luluco}

slug_of() {
  local name
  name=$(basename "$1")
  name=${name//[^A-Za-z0-9._-]/-}
  printf '%s' "${name#.}"
}

collect() {
  local staging=$1 path="" head="" slug base n index dirty tree commit
  git -C "$repo" for-each-ref --format='delete %(refname)' refs/carry | git -C "$repo" update-ref --stdin
  : > "$staging/ignored.txt"
  : > "$staging/summary.txt"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path=${line#worktree }; head="" ;;
      "HEAD "*) head=${line#HEAD } ;;
      "bare" | "prunable"*) path="" ;;
      "")
        if [ -n "$path" ] && [ -n "$head" ] && [ -d "$path" ]; then
          slug=$(slug_of "$path")
          # Two worktrees with the same directory name keep separate refs.
          base=$slug n=1
          while git -C "$repo" show-ref --quiet --verify "refs/carry/$slug/head"; do
            n=$((n + 1))
            slug=$base-$n
          done
          git -C "$repo" update-ref "refs/carry/$slug/head" "$head"
          dirty=no
          if [ -n "$(git -C "$path" status --porcelain --ignore-submodules=dirty)" ]; then
            index=$(mktemp)
            # Start from the real index so unchanged files are not rehashed.
            cp "$(git -C "$path" rev-parse --path-format=absolute --git-path index)" "$index" 2>/dev/null || rm -f "$index"
            tree=$(GIT_INDEX_FILE=$index git -C "$path" add -A >/dev/null &&
              GIT_INDEX_FILE=$index git -C "$path" write-tree)
            rm -f "$index"
            commit=$(git -C "$path" commit-tree "$tree" -p "$head" -m "carry: uncommitted work in $slug")
            git -C "$repo" update-ref "refs/carry/$slug/dirty" "$commit"
            dirty=yes
          fi
          git -C "$path" ls-files --others --ignored --exclude-standard --directory |
            grep -Ev '(^|/)target/' | sed "s|^|$slug: |" >> "$staging/ignored.txt" || true
          printf '%s\t%s\tdirty=%s\t%s\n' "$slug" "$head" "$dirty" "$path" >> "$staging/summary.txt"
        fi
        path=""
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain; echo)
  git -C "$repo" bundle create --quiet "$staging/carry.bundle" --glob='refs/carry/*'
}

if [ "${1:-}" = --collect ]; then
  collect "$2"
  exit 0
fi

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
if [ "$(id -u)" = 0 ]; then
  chown "$user" "$staging"
  runuser -u "$user" -- "$0" --collect "$staging"
elif [ "$(id -un)" = "$user" ]; then
  "$0" --collect "$staging"
else
  echo "coda-carry: run as root or as $user" >&2
  exit 1
fi
install -d -m 0755 "$out"
for file in carry.bundle ignored.txt summary.txt; do
  install -m 0644 "$staging/$file" "$out/$file"
done
cat "$out/summary.txt"
echo "coda-carry: $(wc -l < "$out/summary.txt") worktrees in $out/carry.bundle ($(du -h "$out/carry.bundle" | cut -f1))"
