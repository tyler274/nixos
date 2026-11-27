import contextlib
import io
import unittest
from unittest.mock import patch

import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("cleanup", Path(__file__).with_name("docker-zfs-cleanup.py"))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)

P = cleanup.PARENT
A = P + "/" + "a" * 64
B = P + "/" + "b" * 64
C = P + "/" + "c" * 25


def fixture():
    return {
        P: (100, "yes", "legacy", "-"),
        A: (20, "no", "legacy", "-"),
        B: (30, "no", "legacy", A + "@1"),
        C: (40, "no", "legacy", B + "@2"),
    }


class CleanupTests(unittest.TestCase):
    def test_clone_order(self):
        self.assertEqual(cleanup.plan(fixture()), [C, B, A])
        self.assertEqual(cleanup.plan({P: fixture()[P]}), [])

    def test_refuse_unsafe_inventory(self):
        variants = []
        for row in [(20, "yes", "legacy", "-"), (20, "no", "/important", "-"),
                    (20, "no", "legacy", "other/data@1")]:
            rows = fixture()
            rows[A] = row
            variants.append(rows)
        for name in [P + "/volumes", A + "/child", P + "/" + "f" * 63]:
            rows = fixture()
            rows[name] = (1, "no", "legacy", "-")
            variants.append(rows)
        rows = fixture()
        rows[A] = (20, "no", "legacy", C + "@3")
        variants.extend([rows, {}])
        for rows in variants:
            with self.subTest(rows=rows), self.assertRaises(RuntimeError):
                cleanup.plan(rows)

    def test_driver_and_root_guards(self):
        for info in ['{"Driver":"zfs","DockerRootDir":"/var/lib/docker"}',
                     '{"Driver":"overlay2","DockerRootDir":"/other"}']:
            with patch.object(cleanup, "run", return_value=info), self.assertRaises(RuntimeError):
                cleanup.check_docker()
        with patch.object(cleanup, "run", side_effect=[
            '{"Driver":"overlay2","DockerRootDir":"/var/lib/docker"}',
            '{"filesystems":[{"source":"other","fstype":"zfs"}]}',
        ]), self.assertRaises(RuntimeError):
            cleanup.check_docker()

    def test_snapshot_protection(self):
        with patch.object(cleanup, "run", return_value="other/protected"), self.assertRaises(RuntimeError):
            cleanup.check_snapshots([A + "@1"], {B})
        with patch.object(cleanup, "run", side_effect=["-", "1"]), self.assertRaises(RuntimeError):
            cleanup.check_snapshots([A + "@1"], set())

    def test_apply_only_explicit_snapshots_and_layers(self):
        rows = fixture()
        calls = []

        def execute(*args):
            calls.append(args)
            if args[0:2] == ("zfs", "destroy") and "@" not in args[2]:
                del rows[args[2]]
            return ""

        def snaps(name):
            if name == P:
                return [P + "@keep", A + "@1", B + "@2"]
            return {A: [A + "@1"], B: [B + "@2"], C: []}[name]

        with patch("sys.argv", ["cleanup", "--apply"]), \
             patch.object(cleanup, "check_docker"), \
             patch.object(cleanup, "live_inventory", side_effect=lambda: dict(rows)), \
             patch.object(cleanup, "snapshots", side_effect=snaps), \
             patch.object(cleanup, "check_snapshots"), \
             patch.object(cleanup, "run", side_effect=execute), \
             contextlib.redirect_stdout(io.StringIO()):
            cleanup.main()
        self.assertEqual(calls, [
            ("zfs", "destroy", C), ("zfs", "destroy", B + "@2"),
            ("zfs", "destroy", B), ("zfs", "destroy", A + "@1"),
            ("zfs", "destroy", A),
        ])
        self.assertEqual(set(rows), {P})

    def test_dry_run_never_destroys(self):
        with patch("sys.argv", ["cleanup"]), patch.object(cleanup, "check_docker"), \
             patch.object(cleanup, "live_inventory", return_value=fixture()), \
             patch.object(cleanup, "snapshots", return_value=[]), \
             patch.object(cleanup, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            cleanup.main()
        run.assert_not_called()

    def test_offline_apply_rejected(self):
        with patch("sys.argv", ["cleanup", "--inventory", "unused", "--apply"]), \
             contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            cleanup.main()


if __name__ == "__main__":
    unittest.main()
