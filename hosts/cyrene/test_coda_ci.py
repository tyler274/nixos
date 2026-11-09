import copy
import unittest
from unittest.mock import Mock, call, patch
import tempfile
from pathlib import Path

from coda_ci import main, reconcile, register, run_identity, validate_environment


class RunnerPolicyTests(unittest.TestCase):
    def setUp(self):
        self.environment = {
            "protection_rules": [{"type": "required_reviewers", "reviewers": [{"id": 1}], "prevent_self_review": True}],
            "can_admins_bypass": False,
            "deployment_branch_policy": {"custom_branch_policies": True},
        }

    def test_attempts_and_runs_have_distinct_routing(self):
        identities = {run_identity({"id": run, "run_attempt": attempt}) for run, attempt in ((1, 1), (1, 2), (2, 1))}
        self.assertEqual(len(identities), 3)

    def test_reconcile_removes_only_owned_idle_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "job-old").mkdir()
            (root / "unrelated").mkdir()
            with patch("coda_ci.api", side_effect=[{"runners": [
                {"id": 1, "name": "cyrene-coda-1-1", "busy": False},
                {"id": 2, "name": "other", "busy": False},
            ]}, None]) as request:
                reconcile("token", root)
                self.assertEqual(request.call_args_list, [
                    call("token", "repos/Coda-Health/coda-rust/actions/runners?per_page=100&page=1"),
                    call("token", "repos/Coda-Health/coda-rust/actions/runners/1", method="DELETE"),
                ])
            self.assertFalse((root / "job-old").exists())
            self.assertTrue((root / "unrelated").exists())

    def test_busy_runner_prevents_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "job-active").mkdir()
            with patch("coda_ci.api", return_value={"runners": [{"id": 1, "name": "cyrene-coda-1-1", "busy": True}]}):
                with self.assertRaisesRegex(ValueError, "still busy"):
                    reconcile("token", root)
            self.assertTrue((root / "job-active").exists())

    def test_exact_policy_passes(self):
        validate_environment(self.environment)

    def test_registration_uses_repository_jit_endpoint(self):
        registration = {"runner": {"id": 7}, "encoded_jit_config": "jit"}
        with patch("coda_ci.api", return_value=registration) as request:
            self.assertEqual(register("token", "cyrene-coda-1-2"), registration)
        request.assert_called_once_with(
            "token", "repos/Coda-Health/coda-rust/actions/runners/generate-jitconfig",
            {"name": "cyrene-coda-1-2", "runner_group_id": 1,
             "labels": ["cyrene-coda-1-2"], "work_folder": "_work"},
        )

    def test_main_rejects_invalid_environment_before_registration(self):
        policies = [
            {"total_count": 0, "branch_policies": []},
            {"total_count": 2, "branch_policies": [{"name": "main", "type": "branch"}]},
            {"total_count": 1, "branch_policies": [{"name": "other", "type": "branch"}]},
            {"total_count": 1, "branch_policies": [{"name": "main", "type": "tag"}]},
        ]
        cases = [[self.environment | {"can_admins_bypass": True}]]
        cases += [[self.environment, policy] for policy in policies]
        for responses in cases:
            with self.subTest(responses=responses), patch.dict("os.environ", {"CREDENTIALS_DIRECTORY": "/credentials"}), \
                    patch("coda_ci.Path.read_text", return_value="token"), patch("coda_ci.signal.signal"), \
                    patch("coda_ci.api", side_effect=responses) as request, patch("coda_ci.register") as registration:
                with self.assertRaises(ValueError):
                    main()
                registration.assert_not_called()
                self.assertTrue(all("/environments/cyrene-approval" in item.args[1]
                                    for item in request.call_args_list))

    def test_main_deletes_repository_runner_after_guest_failure(self):
        run = {"id": 1, "run_attempt": 2, "event": "workflow_dispatch", "head_branch": "main",
               "display_title": "Cyrene " + "a" * 40}
        responses = [
            self.environment,
            {"total_count": 1, "branch_policies": [{"name": "main", "type": "branch"}]},
            {"runners": []},
            {"workflow_runs": [run]},
            {"jobs": [{"name": "Cyrene qualification", "status": "queued"}]},
            {"runner": {"id": 7}, "encoded_jit_config": "jit"},
            None,
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "github-token").write_text("token")
            (root / "cyrene-coda-1-2.qcow2").touch()
            environment = {"CREDENTIALS_DIRECTORY": directory, "CODA_CI_SCRATCH": directory,
                           "CODA_CI_CACHE": directory, "CODA_CI_VM": "unused", "PATH": "", "HOME": directory}
            with patch.dict("os.environ", environment, clear=True), patch("coda_ci.signal.signal"), \
                    patch("coda_ci.available_memory", return_value=32 * 1024**3), \
                    patch("coda_ci.shutil.disk_usage", return_value=Mock(free=200 * 1024**3)), \
                    patch("coda_ci.api", side_effect=responses) as request, \
                    patch("coda_ci.subprocess.Popen", side_effect=RuntimeError("guest failed")):
                with self.assertRaisesRegex(RuntimeError, "guest failed"):
                    main()
            self.assertEqual(request.call_args, call(
                "token", "repos/Coda-Health/coda-rust/actions/runners/7", method="DELETE"))
            self.assertEqual(request.call_count, len(responses))

    def test_missing_approval_and_bypass_are_rejected(self):
        for key, value in (("protection_rules", []), ("can_admins_bypass", True),
                           ("deployment_branch_policy", None)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_environment(self.environment | {key: value})
        environment = copy.deepcopy(self.environment)
        environment["protection_rules"][0]["prevent_self_review"] = False
        with self.assertRaises(ValueError):
            validate_environment(environment)


if __name__ == "__main__":
    unittest.main()
