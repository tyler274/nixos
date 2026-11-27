"""Exercise the evaluated agents-pool script without touching real storage."""
import os
import subprocess

script = subprocess.check_output([
    "nix", "eval", "--no-write-lock-file", "--raw",
    ".#nixosConfigurations.Cyrene.config.systemd.services.agents-pool.script",
], text=True)

mocks = r'''
zpool() { return 0; }
zfs() {
  case "$1" in
    get) printf 'available\n' ;;
    list) test "$MODE" != missing-optional ;;
    mount) return 1 ;;
    *) return 99 ;;
  esac
}
findmnt() {
  case "$3" in
    /var/cache/ccache) printf 'agents/ccache\n' ;;
    /agents/coda/build) test "$MODE" != missing-required && printf 'agents/coda/build\n' ;;
    /agents/coda/ci) printf 'agents/coda/ci\n' ;;
    /agents/coda/src) printf 'agents/coda/src\n' ;;
    *) return 1 ;;
  esac
}
export -f zpool zfs findmnt
bash -eu -c "$SCRIPT"
'''
for mode, success in [("missing-optional", True), ("failed-optional-mount", True), ("missing-required", False)]:
    result = subprocess.run(["bash", "-eu", "-c", mocks], env=os.environ | {"SCRIPT": script, "MODE": mode},
                            capture_output=True, text=True)
    if (result.returncode == 0) != success:
        raise AssertionError(f"{mode}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    print(f"PASS: {mode}")
