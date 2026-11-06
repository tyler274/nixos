import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from launcher import Installation


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "data"
        self.spec = {
            "version": "test", "bottle": "Linear", "bottles": "/bin/bottles-cli",
            "runner": {"name": "pinned-ge", "path": "/nix/store/pinned-ge"},
            "parameters": {"custom_dpi": 96}, "arguments": [],
            "executable": "/nix/store/linear/Linear.exe",
        }
        self.installation = Installation(self.spec, self.root)

    def initialize(self, args, **kwargs):
        prefix = self.installation.prefix
        for name in ("system.reg", "user.reg", "drive_c/windows/system32/kernel32.dll"):
            path = prefix / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        (prefix / "drive_c/windows/syswow64").mkdir(parents=True, exist_ok=True)

    def test_repeated_setup_preserves_account_data(self):
        with patch.object(self.installation, "cli", side_effect=self.initialize) as cli:
            self.installation.setup()
            account = self.installation.prefix / "account-sentinel"
            account.write_text("untouched")
            self.installation.setup()
            self.assertEqual(cli.call_count, 1)
            self.assertEqual(account.read_text(), "untouched")

    def test_unmanaged_directory_is_not_adopted(self):
        self.root.mkdir()
        sentinel = self.root / "bottle.yml"
        sentinel.write_text("not ours")
        with self.assertRaisesRegex(RuntimeError, "nonempty"):
            self.installation.setup()
        self.assertEqual(sentinel.read_text(), "not ours")

    def test_different_installation_is_not_overwritten(self):
        with patch.object(self.installation, "cli", side_effect=self.initialize):
            self.installation.setup()
        changed = copy.deepcopy(self.spec)
        changed["version"] = "new"
        with self.assertRaisesRegex(RuntimeError, "different"):
            Installation(changed, self.root).setup()
        self.assertEqual(json.loads((self.root / ".installation.json").read_text()), self.spec)

    def test_failed_initialization_can_be_retried(self):
        with patch.object(self.installation, "cli", side_effect=subprocess.TimeoutExpired("bottles", 1)):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.installation.setup()
        self.assertFalse((self.root / ".ready").exists())
        with patch.object(self.installation, "cli", side_effect=self.initialize):
            self.installation.setup()
        self.assertTrue((self.root / ".ready").exists())

    def test_invalid_urls_never_start_setup(self):
        for urls in (["https://linear.app"], ["--no-sandbox"], ["linear://x", "linear://y"], ["linear://a\nb"]):
            with self.subTest(urls=urls), patch.object(self.installation, "setup") as setup:
                with self.assertRaises(RuntimeError):
                    self.installation.launch(urls)
                setup.assert_not_called()

    def test_callback_is_one_argument_and_output_is_suppressed(self):
        url = "linear://callback?code=private&state=a%20b'$()"
        with patch.object(self.installation, "setup"), patch("subprocess.run") as run:
            self.installation.launch([url])
        args, kwargs = run.call_args
        self.assertEqual(args[0][-3:], ["--", "--", url])
        self.assertIs(kwargs["stdout"], subprocess.DEVNULL)
        self.assertIs(kwargs["stderr"], subprocess.DEVNULL)
        self.assertTrue(kwargs["check"])
        self.assertNotIn("shell", kwargs)

    def test_host_loader_and_wine_environment_is_removed(self):
        with patch.dict(os.environ, {"LD_LIBRARY_PATH": "bad", "LD_PRELOAD": "bad", "WINEPREFIX": "live"}):
            env = Installation(self.spec, self.root).env
        for key in ("LD_LIBRARY_PATH", "LD_PRELOAD", "WINEPREFIX"):
            self.assertNotIn(key, env)
        self.assertEqual(env["FORCE_OFFLINE"], "1")
        self.assertEqual(env["XDG_DATA_HOME"], str(self.root))

    def test_symlink_data_root_is_rejected(self):
        target = Path(self.temp.name) / "target"
        target.mkdir()
        self.root.symlink_to(target)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            self.installation.setup()
        self.assertEqual(list(target.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
