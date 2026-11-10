#!/usr/bin/env bash
# Scratch-repository test for hosts/cyrene/coda-carry.sh:
#   nix build .#checks.x86_64-linux.coda-carry -L
# (or run it directly with git on PATH: tests/coda-carry.sh <coda-carry>)
set -euo pipefail
carry=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work GIT_CONFIG_NOSYSTEM=1
git config --global user.name test
git config --global user.email test@test
git config --global init.defaultBranch main

repo=$work/coda-rust
git init -q "$repo"
printf 'target/\n*.log\n' > "$repo/.gitignore"
echo one > "$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm one

git -C "$repo" worktree add -q "$work/feature" -b feature
echo two > "$work/feature/a.txt"
echo staged > "$work/feature/staged.txt"
git -C "$work/feature" add staged.txt
echo new > "$work/feature/untracked.txt"
mkdir -p "$work/feature/target" && echo big > "$work/feature/target/out"
echo keep > "$work/feature/notes.log"
status_before=$(git -C "$work/feature" status --porcelain)
index_before=$(git -C "$work/feature" ls-files -s | sha256sum)

git -C "$repo" worktree add -q "$work/clean" -b clean
mkdir "$work/other"
git -C "$repo" worktree add -q "$work/other/clean" -b clean2

CODA_CARRY_REPO=$repo CODA_CARRY_OUT=$work/out CODA_CARRY_USER=$(id -un) "$carry"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The worktree is untouched.
[ "$(git -C "$work/feature" status --porcelain)" = "$status_before" ] || fail "feature status changed"
[ "$(git -C "$work/feature" ls-files -s | sha256sum)" = "$index_before" ] || fail "feature index changed"
[ -z "$(git -C "$work/feature" stash list)" ] || fail "a stash was created"

# Refs: head for each worktree, dirty only for the dirty one.
heads=$(git bundle list-heads "$work/out/carry.bundle" | cut -d' ' -f2 | sort)
expected=$(printf '%s\n' refs/carry/clean-2/head refs/carry/clean/head refs/carry/coda-rust/head \
  refs/carry/feature/dirty refs/carry/feature/head | sort)
[ "$heads" = "$expected" ] || fail "bundle refs: $heads"

# The bundle restores the dirty snapshot in a fresh clone.
git init -q "$work/restore"
git -C "$work/restore" fetch -q "$work/out/carry.bundle" 'refs/carry/*:refs/carry/*'
git -C "$work/restore" -c advice.detachedHead=false checkout -q refs/carry/feature/dirty
[ "$(cat "$work/restore/a.txt")" = two ] || fail "modified file missing"
[ "$(cat "$work/restore/staged.txt")" = staged ] || fail "staged file missing"
[ "$(cat "$work/restore/untracked.txt")" = new ] || fail "untracked file missing"
[ ! -e "$work/restore/target" ] || fail "ignored target/ was carried"
[ "$(git -C "$work/restore" rev-parse refs/carry/feature/dirty^)" = "$(git -C "$repo" rev-parse feature)" ] ||
  fail "dirty snapshot is not on top of HEAD"

# Ignored files outside target/ are listed, target/ is not.
grep -qx 'feature: notes.log' "$work/out/ignored.txt" || fail "notes.log not listed"
! grep -q 'target' "$work/out/ignored.txt" || fail "target/ listed"

# A second run replaces the refs rather than accumulating them.
git -C "$work/feature" add -A && git -C "$work/feature" commit -qm two
CODA_CARRY_REPO=$repo CODA_CARRY_OUT=$work/out CODA_CARRY_USER=$(id -un) "$carry" >/dev/null
! git bundle list-heads "$work/out/carry.bundle" | grep -q feature/dirty || fail "stale dirty ref kept"

echo "coda-carry: all checks passed"
