# coda-ci act [<repo-path-or-commit>] [job]
#
# Queue one local act run of a coda-rust commit on Cyrene's Firecracker CI
# and wait for its result. The argument is a repository path (its HEAD runs)
# or a commit in the current repository; the job defaults to ci. The bundle
# is built in a scratch repository borrowing the source's objects, so the
# source repository gains no refs.
spool=${CODA_CI_SPOOL:-/agents/coda/ci/spool}

usage() {
  echo "usage: coda-ci act [<repo-path-or-commit>] [job]" >&2
  exit 2
}

[ "${1:-}" = act ] || usage
shift
target=${1:-.}
job=${2:-ci}
[ $# -le 2 ] || usage
[[ $job =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "coda-ci: bad job name: $job" >&2; exit 2; }

if [ -d "$target" ]; then
  repo=$target
  rev=HEAD
else
  repo=.
  rev=$target
fi
commit=$(git -C "$repo" rev-parse --verify --quiet "$rev^{commit}") ||
  { echo "coda-ci: $rev is not a commit in $repo" >&2; exit 2; }
objects=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/objects

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git init --quiet --bare "$scratch/repo"
echo "$objects" > "$scratch/repo/objects/info/alternates"
git -C "$scratch/repo" update-ref refs/coda-ci/head "$commit"
git -C "$scratch/repo" bundle create --quiet "$scratch/repo.bundle" refs/coda-ci/head

id=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
install -m 0644 "$scratch/repo.bundle" "$spool/requests/$id.bundle"
# The job file goes last and appears whole, by rename: it marks the request
# complete.
printf '%s\n' "$job" > "$spool/requests/.$id.job.part"
mv "$spool/requests/.$id.job.part" "$spool/requests/$id.job"
echo "coda-ci: queued $id: act -j $job at $commit" >&2

result=$spool/results/$id
until [ -e "$result/status" ]; do
  sleep 5
done
cat "$result/log" 2>/dev/null || true
status=$(cat "$result/status")
echo "coda-ci: $id exited $status" >&2
exit "$status"
