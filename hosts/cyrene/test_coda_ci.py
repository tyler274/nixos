import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

import coda_ci
from coda_ci import (
    Config, GuestFailed, MIB, REJECTED, GUEST_FAILED, admit, claim_request, next_github_job,
    next_local_request, one_pass, reconcile, register, run_local, RequestRejected,
)


def make_config(root, **overrides):
    values = dict(root=Path(root), runner="/bin/false", guest_mem_mib=12288, margin_mib=4096,
                  max_bundle_bytes=1024, work_disk_size="1G")
    values.update(overrides)
    config = Config(**values)
    for directory in (config.jobs, config.requests, config.results, config.logs):
        directory.mkdir(parents=True, exist_ok=True)
    return config


def add_request(requests, request_id, job="ci", bundle=b"bundle", mtime=None):
    (requests / f"{request_id}.bundle").write_bytes(bundle)
    (requests / f"{request_id}.job").write_text(job + "\n")
    if mtime is not None:
        os.utime(requests / f"{request_id}.job", (mtime, mtime))


class GithubQueueTests(unittest.TestCase):
    def test_routes_only_jobs_labelled_for_cyrene(self):
        responses = {
            "repos/Coda-Health/coda-rust/actions/runs?status=queued&per_page=50": {"workflow_runs": [
                {"id": 2, "created_at": "2026-01-02T00:00:00Z"},
                {"id": 1, "created_at": "2026-01-01T00:00:00Z"},
            ]},
            "repos/Coda-Health/coda-rust/actions/runs/1/jobs?filter=latest&per_page=100": {"jobs": [
                {"id": 10, "status": "queued", "labels": ["blacksmith-4vcpu-ubuntu-2404"]},
                {"id": 11, "status": "in_progress", "labels": ["cyrene-coda"]},
            ]},
            "repos/Coda-Health/coda-rust/actions/runs/2/jobs?filter=latest&per_page=100": {"jobs": [
                {"id": 20, "status": "queued", "labels": ["cyrene-coda"]},
            ]},
        }
        with patch("coda_ci.api", side_effect=lambda token, path: responses[path]):
            self.assertEqual(next_github_job("token")["id"], 20)

    def test_no_labelled_job_means_none(self):
        with patch("coda_ci.api", side_effect=[
            {"workflow_runs": [{"id": 1, "created_at": "x"}]},
            {"jobs": [{"id": 10, "status": "queued", "labels": ["ubuntu-latest"]}]},
        ]):
            self.assertIsNone(next_github_job("token"))

    def test_registration_uses_the_shared_label_and_a_unique_name(self):
        with patch("coda_ci.api", return_value={"runner": {"id": 7}}) as request:
            register("token", 42)
            register("token", 42)
        first, second = (item.args[2] for item in request.call_args_list)
        self.assertEqual(first["labels"], ["cyrene-coda"])
        self.assertRegex(first["name"], r"^cyrene-coda-42-[0-9a-f]{6}$")
        self.assertNotEqual(first["name"], second["name"])
        self.assertEqual(request.call_args.args[1],
                         "repos/Coda-Health/coda-rust/actions/runners/generate-jitconfig")

    def test_github_runs_before_local_requests(self):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(directory)
            add_request(config.requests, "a" * 12)
            with patch("coda_ci.next_github_job", return_value={"id": 5, "name": "ci"}), \
                    patch("coda_ci.admit", return_value=True), \
                    patch("coda_ci.run_github") as github, patch("coda_ci.run_local") as local:
                one_pass(config, "token")
            github.assert_called_once()
            local.assert_not_called()

    def test_without_a_token_only_local_requests_run(self):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(directory)
            add_request(config.requests, "a" * 12)
            with patch("coda_ci.next_github_job") as github, patch("coda_ci.admit", return_value=True), \
                    patch("coda_ci.run_local") as local:
                one_pass(config, None)
            github.assert_not_called()
            local.assert_called_once_with(config, "a" * 12)


class ReconcileTests(unittest.TestCase):
    def test_removes_owned_idle_runners_and_all_job_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            jobs = Path(directory)
            (jobs / "local-old").mkdir()
            (jobs / "local-old" / "work.img").touch()
            with patch("coda_ci.api", side_effect=[{"runners": [
                {"id": 1, "name": "cyrene-coda-1-abcdef", "busy": False},
                {"id": 2, "name": "other", "busy": False},
            ]}, None]) as request:
                reconcile("token", jobs)
            self.assertEqual(request.call_args_list, [
                call("token", "repos/Coda-Health/coda-rust/actions/runners?per_page=100&page=1"),
                call("token", "repos/Coda-Health/coda-rust/actions/runners/1", method="DELETE"),
            ])
            self.assertEqual(list(jobs.iterdir()), [])

    def test_busy_runner_prevents_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            jobs = Path(directory)
            (jobs / "github-1").mkdir()
            with patch("coda_ci.api", return_value={"runners": [
                {"id": 1, "name": "cyrene-coda-1-abcdef", "busy": True}]}):
                with self.assertRaisesRegex(ValueError, "still busy"):
                    reconcile("token", jobs)
            self.assertTrue((jobs / "github-1").exists())


class LocalRequestTests(unittest.TestCase):
    def test_oldest_complete_request_is_next(self):
        with tempfile.TemporaryDirectory() as directory:
            requests = Path(directory)
            add_request(requests, "b" * 12, mtime=200)
            add_request(requests, "a" * 12, mtime=300)
            (requests / ("c" * 12 + ".bundle")).write_bytes(b"no sidecar yet")
            self.assertEqual(next_local_request(requests), "b" * 12)

    def test_names_outside_the_pattern_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            requests = Path(directory)
            for name in ("A" * 12, "a" * 11, "a" * 13, "../" + "a" * 9, "g" * 12):
                (requests / f"{name}.bundle").write_bytes(b"x")
                (requests / f"{name}.job").write_text("ci")
            self.assertIsNone(next_local_request(requests))

    def test_claim_copies_and_removes_the_request(self):
        with tempfile.TemporaryDirectory() as directory:
            requests = Path(directory, "requests")
            inputs = Path(directory, "inputs")
            requests.mkdir()
            inputs.mkdir()
            add_request(requests, "a" * 12, job="build-wasm")
            self.assertEqual(claim_request(requests, "a" * 12, inputs, 1024), "build-wasm")
            self.assertEqual((inputs / "repo.bundle").read_bytes(), b"bundle")
            self.assertEqual((inputs / "job").read_text(), "build-wasm\n")
            self.assertEqual(list(requests.iterdir()), [])

    def test_claim_rejects_bad_job_names_sizes_and_links(self):
        cases = {
            "name": dict(job="ci; rm -rf /"),
            "long name": dict(job="a" * 65),
            "size": dict(bundle=b"x" * 2048),
        }
        for label, request in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as directory:
                requests = Path(directory, "requests")
                inputs = Path(directory, "inputs")
                requests.mkdir()
                inputs.mkdir()
                add_request(requests, "a" * 12, **request)
                with self.assertRaises(RequestRejected):
                    claim_request(requests, "a" * 12, inputs, 1024)
                self.assertEqual(list(requests.iterdir()), [])
                self.assertFalse((inputs / "repo.bundle").exists())
        with tempfile.TemporaryDirectory() as directory:
            requests = Path(directory, "requests")
            inputs = Path(directory, "inputs")
            requests.mkdir()
            inputs.mkdir()
            secret = Path(directory, "secret")
            secret.write_bytes(b"host secret")
            (requests / ("a" * 12 + ".bundle")).symlink_to(secret)
            (requests / ("a" * 12 + ".job")).write_text("ci")
            with self.assertRaisesRegex(RequestRejected, "cannot be opened"):
                claim_request(requests, "a" * 12, inputs, 1024)
            self.assertTrue(secret.exists())

    def test_rejected_request_gets_a_result(self):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(directory)
            add_request(config.requests, "a" * 12, job="bad job")
            with patch("coda_ci.run_job") as job:
                run_local(config, "a" * 12)
            job.assert_not_called()
            result = config.results / ("a" * 12)
            self.assertEqual((result / "status").read_text(), f"{REJECTED}\n")
            self.assertIn("job name", (result / "log").read_text())


class AdmissionTests(unittest.TestCase):
    def test_guest_and_margin_must_fit_in_available_memory(self):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(directory, guest_mem_mib=12288, margin_mib=4096)
            self.assertTrue(admit(config, 16384 * MIB))
            self.assertFalse(admit(config, 16384 * MIB - 1))

    def test_unadmitted_request_stays_queued(self):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(directory)
            add_request(config.requests, "a" * 12)
            with patch("coda_ci.available_memory", return_value=8 * 1024 * MIB), \
                    patch("coda_ci.run_local") as local:
                one_pass(config, None)
            local.assert_not_called()
            self.assertTrue((config.requests / ("a" * 12 + ".job")).exists())


class GuestFailureTests(unittest.TestCase):
    def test_guest_failure_removes_the_job_directory_and_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(directory)
            add_request(config.requests, "a" * 12)
            created = []

            def fail(config, job_dir, log, keep_going=None):
                created.append(job_dir)
                log.write_bytes(b"booting\n")
                raise GuestFailed("guest exited (1) without reporting a status")

            with patch("coda_ci.clone_seed"), patch("coda_ci.make_inputs"), \
                    patch("coda_ci.run_guest", side_effect=fail):
                run_local(config, "a" * 12)
            self.assertEqual(created, [config.jobs / ("local-" + "a" * 12)])
            self.assertEqual(list(config.jobs.iterdir()), [])
            result = config.results / ("a" * 12)
            self.assertEqual((result / "status").read_text(), f"{GUEST_FAILED}\n")
            self.assertIn("booting", (result / "log").read_text())

    def test_missing_seed_fails_without_leaving_a_job(self):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(directory)
            with self.assertRaisesRegex(FileNotFoundError, "coda-ci-seed"):
                coda_ci.run_job(config, "local-x", Path(directory), Path(directory, "log"))
            self.assertEqual(list(config.jobs.iterdir()), [])

    def test_exit_marker_is_the_job_status(self):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(directory, runner="/bin/sh")
            script = Path(directory, "guest")
            script.write_text("#!/bin/sh\necho noise\necho CODA_JOB_EXIT=3\n")
            script.chmod(0o755)
            config = make_config(directory, runner=str(script))
            job_dir = config.jobs / "j"
            job_dir.mkdir()
            self.assertEqual(coda_ci.run_guest(config, job_dir, Path(directory, "log")), 3)

    def test_runner_is_deleted_after_guest_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            config = make_config(directory)
            with patch("coda_ci.api", side_effect=[{"runner": {"id": 7}, "encoded_jit_config": "jit"}, None]) \
                    as request, patch("coda_ci.run_job", side_effect=GuestFailed("guest failed")):
                with self.assertRaises(GuestFailed):
                    coda_ci.run_github(config, "token", {"id": 9, "name": "ci"})
            self.assertEqual(request.call_args, call(
                "token", "repos/Coda-Health/coda-rust/actions/runners/7", method="DELETE"))


if __name__ == "__main__":
    unittest.main()
