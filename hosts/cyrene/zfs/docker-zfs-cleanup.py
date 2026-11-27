"""Retire Cyrene's old Docker ZFS layers, never the live overlay2 parent."""

import argparse
import json
import re
import subprocess

PARENT = "rpool/docker"
LAYER = re.compile(r"rpool/docker/(?:[0-9a-f]{64}|[a-z0-9]{25})(?:-init)?\Z")


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def inventory(text):
    rows = {}
    for line in text.splitlines():
        name, used, mounted, mountpoint, origin = line.split("\t")
        if name == PARENT or name.startswith(PARENT + "/"):
            rows[name] = (int(used), mounted, mountpoint, origin)
    return rows


def plan(rows):
    if PARENT not in rows or rows[PARENT][1:3] != ("yes", "legacy"):
        raise RuntimeError("Expected the mounted legacy rpool/docker parent")
    layers = set(rows) - {PARENT}
    for name in layers:
        _, mounted, mountpoint, origin = rows[name]
        if not LAYER.fullmatch(name) or mounted != "no" or mountpoint != "legacy":
            raise RuntimeError(f"Unexpected or mounted dataset: {name}")
        if origin != "-" and origin.split("@", 1)[0] not in layers:
            raise RuntimeError(f"Origin outside the retired layer set: {name}: {origin}")

    # Delete clones before the filesystems holding their origin snapshots.
    remaining = set(layers)
    order = []
    while remaining:
        origins = {rows[n][3].split("@", 1)[0] for n in remaining}
        leaves = sorted(remaining - origins)
        if not leaves:
            raise RuntimeError("Cycle in layer clone dependencies")
        order.extend(leaves)
        remaining.difference_update(leaves)
    return order


def check_docker():
    info = json.loads(run("docker", "--host=unix:///run/docker.sock", "info", "--format", "{{json .}}"))
    if info["Driver"] != "overlay2" or info["DockerRootDir"] != "/var/lib/docker":
        raise RuntimeError("Cleanup requires overlay2 at /var/lib/docker")
    mounts = json.loads(run("findmnt", "--json", "--mountpoint", "/var/lib/docker", "-o", "SOURCE,FSTYPE"))
    if mounts["filesystems"] != [{"source": PARENT, "fstype": "zfs"}]:
        raise RuntimeError("Docker root is not mounted from rpool/docker")


def live_inventory():
    # Include volumes so an unexpected zvol causes preflight to fail closed.
    return inventory(run("zfs", "list", "-H", "-p", "-t", "filesystem,volume", "-o",
                         "name,used,mounted,mountpoint,origin", "-r", PARENT))


def snapshots(dataset):
    text = run("zfs", "list", "-H", "-t", "snapshot", "-o", "name", "-r", dataset)
    return text.splitlines() if text else []


def check_snapshots(names, allowed_clones):
    for snap in names:
        clones = run("zfs", "get", "-H", "-o", "value", "clones", snap)
        if clones != "-" and not set(clones.split(",")).issubset(allowed_clones):
            raise RuntimeError(f"Snapshot has protected clones: {snap}: {clones}")
        if run("zfs", "get", "-H", "-o", "value", "userrefs", snap) != "0":
            raise RuntimeError(f"Snapshot has a hold: {snap}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="delete after live safety checks (default: dry run)")
    parser.add_argument("--inventory", help="offline plan from a saved inventory; cannot be used with --apply")
    args = parser.parse_args()
    if args.inventory and args.apply:
        parser.error("--inventory is read-only")
    if args.inventory:
        with open(args.inventory) as handle:
            rows = inventory(handle.read())
    else:
        check_docker()
        rows = live_inventory()
    order = plan(rows)
    print(f"{len(order)} retired layers; summed USED {sum(rows[n][0] for n in order)} bytes", flush=True)
    print("Preserving rpool/docker and its own snapshots, overlay2 data and Docker volumes", flush=True)
    if args.inventory:
        print("Offline plan only: live driver, mounts, snapshot holds and external clones not checked")
        return

    # Check all snapshots before deleting anything, including external clones/holds.
    all_snaps = snapshots(PARENT)
    layer_snaps = [s for s in all_snaps if s.split("@", 1)[0] in rows and s.split("@", 1)[0] != PARENT]
    check_snapshots(layer_snaps, set(order))
    if not args.apply:
        print("Dry run passed; use --apply to remove these retired layers")
        return

    for name in order:
        check_docker()
        current = live_inventory()
        # Reject any new, renamed, mounted or nested datasets during cleanup.
        plan(current)
        if set(current) - set(rows):
            raise RuntimeError("Dataset inventory changed during cleanup")
        if name not in current or current[name][1:] != rows[name][1:]:
            raise RuntimeError(f"Dataset changed during cleanup: {name}")
        snaps = snapshots(name)
        if any(s.split("@", 1)[0] != name for s in snaps):
            raise RuntimeError(f"Unexpected descendant snapshot: {name}")
        check_snapshots(snaps, set())
        for snap in snaps:
            run("zfs", "destroy", snap)
        # No -r, -R, -f, or deferred destruction: dependencies fail safely.
        run("zfs", "destroy", name)
        print(f"Removed {name}", flush=True)
    print("Retired Docker ZFS layers removed", flush=True)


if __name__ == "__main__":
    main()
