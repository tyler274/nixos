"""Start one disposable runner only after checking its GitHub access policy."""

import signal
import shutil
import json
import os
from pathlib import Path
import re
import urllib.error
import subprocess
import tempfile
import time
import urllib.request

REPO = "Coda-Health/coda-rust"
RUNNERS_PATH = f"repos/{REPO}/actions/runners"


def api(token, path, data=None, method=None):
    request = urllib.request.Request(
        "https://api.github.com/" + path,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"}, method=method,
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else None


def register(token, identity):
    return api(token, RUNNERS_PATH + "/generate-jitconfig", {
        "name": identity,
        "runner_group_id": 1,
        "labels": [identity], "work_folder": "_work",
    })


def available_memory():
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) * 1024
    raise ValueError("MemAvailable is unavailable")


def validate_environment(environment):
    reviewers = [rule for rule in environment["protection_rules"] if rule["type"] == "required_reviewers"]
    if not reviewers or not reviewers[0].get("reviewers") or not reviewers[0].get("prevent_self_review"):
        raise ValueError("cyrene-approval needs required reviewers and prevention of self-review")
    if environment.get("can_admins_bypass", True):
        raise ValueError("cyrene-approval must disable administrator bypass")
    policy = environment.get("deployment_branch_policy") or {}
    if not policy.get("custom_branch_policies"):
        raise ValueError("cyrene-approval must restrict deployment branches")


def run_identity(run):
    return f"cyrene-coda-{int(run['id'])}-{int(run['run_attempt'])}"


def reconcile(token, scratch):
    page = 1
    stale = []
    while True:
        runners = api(token, RUNNERS_PATH + f"?per_page=100&page={page}")["runners"]
        for runner in runners:
            if re.fullmatch(r"cyrene-coda-[0-9]+-[0-9]+", runner["name"]):
                if runner["busy"]:
                    raise ValueError("a controller-owned runner is still busy; refusing concurrent execution")
                stale.append(runner["id"])
        if len(runners) < 100:
            break
        page += 1
    for runner in stale:
        api(token, f"{RUNNERS_PATH}/{runner}", method="DELETE")
    for path in scratch.glob("job-*"):
        if path.is_symlink():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)


def main():
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
    token = (Path(os.environ["CREDENTIALS_DIRECTORY"]) / "github-token").read_text().strip()
    environment_path = f"repos/{REPO}/environments/cyrene-approval"
    validate_environment(api(token, environment_path))
    policies = api(token, environment_path + "/deployment-branch-policies")
    if policies["total_count"] != 1 or policies["branch_policies"][0]["name"] != "main" or policies["branch_policies"][0]["type"] != "branch":
        raise ValueError("cyrene-approval must allow only the main branch")
    scratch = Path(os.environ["CODA_CI_SCRATCH"])
    caches = Path(os.environ["CODA_CI_CACHE"])
    reconcile(token, scratch)
    if available_memory() < 24 * 1024**3:
        raise ValueError("Cyrene needs at least 24 GiB available RAM before starting a 16 GiB guest")
    runs = api(token, f"repos/{REPO}/actions/workflows/cyrene.yml/runs?event=workflow_dispatch&branch=main&per_page=20")
    selected = None
    for run in reversed(runs["workflow_runs"]):
        if run["event"] != "workflow_dispatch" or run["head_branch"] != "main":
            continue
        if not re.fullmatch(r"Cyrene [0-9a-f]{40}", run["display_title"]):
            continue
        jobs = api(token, f"repos/{REPO}/actions/runs/{run['id']}/jobs?per_page=100")
        if any(job["name"] == "Cyrene qualification" and job["status"] == "queued" for job in jobs["jobs"]):
            selected = run
            break
    if selected is None:
        print("No approved Cyrene qualification job is queued.")
        return
    if shutil.disk_usage(scratch).free < 180 * 1024**3:
        raise ValueError("CI needs 180 GiB free scratch before starting a guest")
    if shutil.disk_usage(caches).free < 48 * 1024**3:
        raise ValueError("CI needs 48 GiB free encrypted-cache space")
    identity = run_identity(selected)
    cache = caches / f"{identity}.qcow2"
    if not cache.exists():
        subprocess.run(["qemu-img", "create", "-f", "qcow2", str(cache), "48G"], check=True)
    for old in caches.glob("*.qcow2"):
        if old != cache and time.time() - old.stat().st_mtime > 7 * 86400:
            old.unlink()
    if sum(path.stat().st_blocks * 512 for path in caches.glob("*.qcow2")) > 100 * 1024**3:
        raise ValueError("CI cache budget exceeded; remove inactive run caches before retrying")
    runner_id = None
    with tempfile.TemporaryDirectory(prefix="job-", dir=scratch) as work:
        work = Path(work)
        registration = register(token, identity)
        runner_id = registration["runner"]["id"]
        try:
            jit = work / "jit"
            jit.write_text(registration["encoded_jit_config"])
            jit.chmod(0o600)
            env = {key: os.environ[key] for key in ("PATH", "HOME")}
            env.update({"CODA_JIT_FILE": str(jit), "CODA_CACHE_IMAGE": str(cache),
                        "NIX_DISK_IMAGE": str(work / "root.qcow2"), "TMPDIR": str(work),
                        "QEMU_OPTS": "-enable-kvm"})
            print(f"Starting disposable VM for approved run {selected['id']}", flush=True)
            process = subprocess.Popen([os.environ["CODA_CI_VM"]], cwd=work, env=env, start_new_session=True)
            try:
                deadline = time.monotonic() + 10800
                while process.poll() is None:
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        current = api(token, f"repos/{REPO}/actions/runs/{selected['id']}")
                        if current["status"] == "completed" or current["run_attempt"] != selected["run_attempt"]:
                            break
                        if time.monotonic() >= deadline:
                            raise TimeoutError("guest exceeded its three-hour limit")
                if process.returncode not in (None, 0):
                    raise RuntimeError("guest exited unsuccessfully")
            finally:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=20)
                except ProcessLookupError:
                    pass
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        finally:
            try:
                api(token, f"{RUNNERS_PATH}/{runner_id}", method="DELETE")
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise


if __name__ == "__main__":
    main()
