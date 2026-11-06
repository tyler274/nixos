import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        json.dump(value, file, sort_keys=True)
        file.flush()
        os.fsync(file.fileno())
    os.replace(file.name, path)


class Installation:
    def __init__(self, spec, root):
        self.spec = spec
        self.root = Path(root).absolute()
        self.prefix = self.root / "bottles/bottles" / spec["bottle"]
        self.env = os.environ.copy()
        for key in ("LD_LIBRARY_PATH", "LD_PRELOAD", "WINEPREFIX", "WINEARCH"):
            self.env.pop(key, None)
        original_data = self.env.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))
        self.env.update(
            XDG_DATA_HOME=str(self.root),
            XDG_DATA_DIRS=original_data + ":" + self.env.get(
                "XDG_DATA_DIRS", "/usr/local/share:/usr/share"
            ),
            FORCE_OFFLINE="1",
            WINEDLLOVERRIDES="mscoree,mshtml,winemenubuilder=",
            WINEDEBUG="-all",
        )

    def cli(self, args, timeout=None):
        subprocess.run(
            [self.spec["bottles"], *args], env=self.env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=True, timeout=timeout,
        )

    def setup(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.root.is_symlink():
            raise RuntimeError("The Linear data directory must not be a symlink.")
        with (self.root / ".setup.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            marker = self.root / ".installation.json"
            if marker.exists():
                if json.loads(marker.read_text()) != self.spec:
                    raise RuntimeError(
                        "This data directory belongs to a different Linear installation. "
                        "Use a new LINEAR_BOTTLES_DATA_HOME; existing data was not changed."
                    )
            else:
                if any(p.name != ".setup.lock" for p in self.root.iterdir()):
                    raise RuntimeError("Refusing to adopt a nonempty Linear data directory.")
                atomic_json(marker, self.spec)
            ready = self.root / ".ready"
            if ready.exists():
                if not all((self.prefix / p).is_file() for p in (
                    "bottle.yml", "system.reg", "user.reg", "drive_c/windows/system32/kernel32.dll"
                )):
                    raise RuntimeError("The managed Linear bottle is damaged; refusing to overwrite it.")
                return
            runner = self.root / "bottles/runners" / self.spec["runner"]["name"]
            runner.parent.mkdir(parents=True, exist_ok=True)
            if not runner.is_symlink():
                if runner.exists():
                    raise RuntimeError("Refusing to overwrite an existing runner.")
                runner.symlink_to(self.spec["runner"]["path"], target_is_directory=True)
            elif os.readlink(runner) != self.spec["runner"]["path"]:
                raise RuntimeError("The managed runner link has changed.")
            self.prefix.mkdir(parents=True, exist_ok=True)
            config = {
                "Name": self.spec["bottle"],
                "Path": self.spec["bottle"],
                "Runner": self.spec["runner"]["name"],
                "Environment": "Custom",
                "Arch": "win64",
                "Windows": "win10",
                "Parameters": self.spec["parameters"],
                "Environment_Variables": {"WINEDLLOVERRIDES": "mscoree,mshtml,winemenubuilder="},
                "DLL_Overrides": {name: "n,b" for name in ("d3d11", "dxgi", "d3d10core", "d3d9")},
            }
            atomic_json(self.prefix / "bottle.yml", config)
            wineboot = runner / "files/lib/wine/x86_64-windows/wineboot.exe"
            self.cli(["run", "-b", self.spec["bottle"], "-e", str(wineboot), "--", "-u"], timeout=180)
            for registry in ("system.reg", "user.reg"):
                if not (self.prefix / registry).is_file():
                    raise RuntimeError("Bottles failed to initialize the Linear Wine prefix.")
            for arch, directory in (("x86_64", "system32"), ("i386", "syswow64")):
                for name in config["DLL_Overrides"]:
                    target = runner / f"files/lib/wine/dxvk/{arch}-windows/{name}.dll"
                    destination = self.prefix / f"drive_c/windows/{directory}/{name}.dll"
                    temporary = destination.with_suffix(".dll.linear-tmp")
                    temporary.unlink(missing_ok=True)
                    temporary.symlink_to(target)
                    temporary.replace(destination)
            atomic_json(ready, {"version": self.spec["version"]})

    def launch(self, urls):
        if len(urls) > 1 or any(
            urlsplit(url).scheme.lower() != "linear" or any(ord(c) < 32 for c in url)
            for url in urls
        ):
            raise RuntimeError("Expected at most one linear:// URL.")
        self.setup()
        self.cli([
            "run", "-b", self.spec["bottle"], "-e", self.spec["executable"],
            "--", "--", *self.spec["arguments"], *urls,
        ])


def main():
    parser = argparse.ArgumentParser(description="Run the official Linear desktop app using pinned Bottles components.")
    parser.add_argument("spec", type=Path)
    parser.add_argument("command", choices=("setup", "launch"))
    parser.add_argument("urls", nargs="*")
    args = parser.parse_args()
    root = os.environ.get("LINEAR_BOTTLES_DATA_HOME") or str(
        Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "linear-bottles"
    )
    if not Path(root).is_absolute():
        parser.error("LINEAR_BOTTLES_DATA_HOME must be an absolute path")
    try:
        installation = Installation(json.loads(args.spec.read_text()), root)
        if args.command == "setup":
            if args.urls:
                parser.error("setup does not accept URLs")
            installation.setup()
            print("Linear bottle is ready.")
        else:
            installation.launch(args.urls)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print("Linear Bottles failed. Run linear-bottles-setup to check the installation.", file=sys.stderr)
        if args.command == "setup":
            raise
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
