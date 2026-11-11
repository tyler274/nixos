"""Run Coda CI jobs one at a time, each in a disposable Firecracker guest.

One pass takes at most one job: a queued GitHub job labelled cyrene-coda
first, then the oldest local act request from the spool. The guest gets a
reflink clone of the seed work disk and a read-only inputs disk; its serial
console is the only thing that comes back.
"""

import fcntl
import json
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

REPO = "Coda-Health/coda-rust"
LABEL = "cyrene-coda"
RUNNERS_PATH = f"repos/{REPO}/actions/runners"
RUNNER_NAME = re.compile(r"cyrene-coda-[0-9]+-[0-9a-f]+")
REQUEST_ID = re.compile(r"[0-9a-f]{12}")
JOB_NAME = re.compile(r"[A-Za-z0-9_-]{1,64}")
EXIT_MARKER = re.compile(rb"CODA_JOB_EXIT=([0-9]+)")
DEADLINE_SECONDS = 3 * 3600
# A JIT runner that has not picked up a job by then never will.
IDLE_GRACE_SECONDS = 600
MIB = 1024**2
GUEST_FAILED = 255
REJECTED = 125
RESULT_DAYS = 7
GITHUB_LOGS_KEPT = 20


class RequestRejected(Exception):
    """A local request that cannot run; the reason goes to its result."""


class GuestFailed(Exception):
    """The guest ended without reporting the job's exit status."""


@dataclass(frozen=True)
class Config:
    root: Path
    runner: str
    guest_mem_mib: int
    margin_mib: int
    max_bundle_bytes: int
    work_disk_size: str

    @classmethod
    def from_env(cls):
        env = os.environ
        return cls(
            root=Path(env["CODA_CI_ROOT"]),
            runner=env["CODA_CI_RUNNER"],
            guest_mem_mib=int(env["CODA_CI_GUEST_MEM_MIB"]),
            margin_mib=int(env.get("CODA_CI_MARGIN_MIB", "4096")),
            max_bundle_bytes=int(env.get("CODA_CI_MAX_BUNDLE_MIB", "4096")) * MIB,
            work_disk_size=env.get("CODA_CI_WORK_DISK_SIZE", "200G"),
        )

    @property
    def seed(self):
        return self.root / "seed" / "work.img"

    @property
    def jobs(self):
        return self.root / "jobs"

    @property
    def requests(self):
        return self.root / "spool" / "requests"

    @property
    def results(self):
        return self.root / "spool" / "results"

    @property
    def logs(self):
        return self.root / "logs"


def api(token, path, data=None, method=None):
    base = os.environ.get("CODA_CI_API", "https://api.github.com")
    request = urllib.request.Request(
        f"{base}/{path}",
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"}, method=method,
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else None


def delete_runner(token, runner_id):
    try:
        api(token, f"{RUNNERS_PATH}/{runner_id}", method="DELETE")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise


def reconcile(token, jobs):
    """Remove what an interrupted pass left: idle runners and job directories."""
    if token is not None:
        page = 1
        stale = []
        while True:
            runners = api(token, RUNNERS_PATH + f"?per_page=100&page={page}")["runners"]
            for runner in runners:
                if RUNNER_NAME.fullmatch(runner["name"]):
                    if runner["busy"]:
                        raise ValueError("a controller-owned runner is still busy; refusing concurrent execution")
                    stale.append(runner["id"])
            if len(runners) < 100:
                break
            page += 1
        for runner in stale:
            delete_runner(token, runner)
    for path in jobs.iterdir():
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()


def next_github_job(token):
    """The oldest queued job whose labels ask for this machine."""
    runs = api(token, f"repos/{REPO}/actions/runs?status=queued&per_page=50")["workflow_runs"]
    for run in sorted(runs, key=lambda run: run["created_at"]):
        jobs = api(token, f"repos/{REPO}/actions/runs/{int(run['id'])}/jobs?filter=latest&per_page=100")["jobs"]
        for job in jobs:
            if job["status"] == "queued" and LABEL in job["labels"]:
                return job
    return None


def register(token, job_id):
    return api(token, RUNNERS_PATH + "/generate-jitconfig", {
        "name": f"cyrene-coda-{int(job_id)}-{secrets.token_hex(3)}",
        "runner_group_id": 1,
        "labels": [LABEL],
        "work_folder": "_work",
    })


def next_local_request(requests):
    """The id of the oldest complete request; the .job sidecar is written last."""
    ready = []
    for sidecar in requests.glob("*.job"):
        request_id = sidecar.name.removesuffix(".job")
        if REQUEST_ID.fullmatch(request_id) and (requests / f"{request_id}.bundle").exists():
            ready.append((sidecar.lstat().st_mtime, request_id))
    return min(ready)[1] if ready else None


def copy_regular(path, destination, limit):
    """Copy a file a client wrote without following links or exceeding limit."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise RequestRejected(f"{path.name} cannot be opened: {error.strerror}") from error
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise RequestRejected(f"{path.name} is not a regular file")
        if info.st_size > limit:
            raise RequestRejected(f"{path.name} is {info.st_size} bytes; the limit is {limit}")
        copied = 0
        with open(destination, "wb") as target:
            # The client may still be writing; never copy past the limit.
            while copied <= limit and (chunk := source.read(min(MIB, limit + 1 - copied))):
                target.write(chunk)
                copied += len(chunk)
        if copied > limit:
            destination.unlink()
            raise RequestRejected(f"{path.name} grew past the limit of {limit} bytes")


def claim_request(requests, request_id, destination, max_bundle_bytes):
    """Copy a request into the job's inputs and remove it from the spool.

    The bundle is never parsed on the host; only the guest opens it.
    """
    bundle = requests / f"{request_id}.bundle"
    sidecar = requests / f"{request_id}.job"
    try:
        copy_regular(sidecar, destination / "job", 128)
        job = (destination / "job").read_bytes().decode("ascii", "replace").strip()
        if not JOB_NAME.fullmatch(job):
            (destination / "job").unlink()
            raise RequestRejected(f"job name {job[:64]!r} is not [A-Za-z0-9_-]{{1,64}}")
        (destination / "job").write_text(job + "\n")
        copy_regular(bundle, destination / "repo.bundle", max_bundle_bytes)
        return job
    finally:
        for path in (bundle, sidecar):
            path.unlink(missing_ok=True)


ARC_EVICTABLE = (
    "mru_evictable_data",
    "mru_evictable_metadata",
    "mfu_evictable_data",
    "mfu_evictable_metadata",
)


def reclaimable_arc(arcstats=Path("/proc/spl/kstat/zfs/arcstats")):
    """ZFS ARC the kernel can give back under pressure, which MemAvailable omits.

    Only the evictable lists count, and never below the ARC's floor (c_min).
    A host without ZFS has none.
    """
    try:
        text = arcstats.read_text()
    except FileNotFoundError:
        return 0
    stats = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2].isdigit():
            stats[fields[0]] = int(fields[2])
    evictable = sum(stats.get(name, 0) for name in ARC_EVICTABLE)
    return max(0, min(evictable, stats.get("size", 0) - stats.get("c_min", 0)))


def available_memory():
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) * 1024 + reclaimable_arc()
    raise ValueError("MemAvailable is unavailable")


def admit(config, available=None):
    """Start a guest only if it fits with the margin left over."""
    if available is None:
        available = available_memory()
    return (config.guest_mem_mib + config.margin_mib) * MIB <= available


def clone_seed(seed, destination):
    if not seed.is_file():
        raise FileNotFoundError(f"no seed work disk at {seed}; run coda-ci-seed first")
    subprocess.run(["cp", "--reflink=always", str(seed), str(destination)], check=True)


def make_disk(path, size, source=None, label="work"):
    subprocess.run(["truncate", "-s", str(size), str(path)], check=True)
    command = ["mkfs.ext4", "-q", "-F", "-m", "0", "-L", label]
    if source is not None:
        command += ["-d", str(source)]
    subprocess.run(command + [str(path)], check=True)


def make_inputs(path, source):
    payload = sum(item.stat().st_size for item in source.rglob("*") if item.is_file())
    make_disk(path, payload + payload // 10 + 32 * MIB, source, label="inputs")


def stop(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=20)
    except ProcessLookupError:
        pass
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def run_guest(config, job_dir, log_path, keep_going=None):
    """Boot the guest in job_dir and return the job's exit status."""
    env = {"PATH": os.environ["PATH"], "HOME": str(job_dir), "TMPDIR": str(job_dir)}
    with open(log_path, "wb") as log:
        process = subprocess.Popen([config.runner], cwd=job_dir, env=env, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + DEADLINE_SECONDS
            while process.poll() is None:
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    if time.monotonic() >= deadline:
                        raise GuestFailed("guest exceeded its three-hour limit")
                    if keep_going is not None and not keep_going():
                        raise GuestFailed("the GitHub job ended without this runner")
        finally:
            stop(process)
    markers = EXIT_MARKER.findall(log_path.read_bytes())
    if not markers:
        raise GuestFailed(f"guest exited ({process.returncode}) without reporting a status")
    return int(markers[-1])


def run_job(config, job_id, inputs, log_path, keep_going=None):
    """Run one job in its own directory and always remove the directory."""
    job_dir = config.jobs / job_id
    job_dir.mkdir()
    try:
        clone_seed(config.seed, job_dir / "work.img")
        make_inputs(job_dir / "inputs.img", inputs)
        return run_guest(config, job_dir, log_path, keep_going)
    finally:
        shutil.rmtree(job_dir)


def write_result(results, request_id, status, log=None, message=None):
    """Publish log then status; the client treats status as completion."""
    directory = results / request_id
    directory.mkdir(mode=0o755, exist_ok=True)
    os.chmod(directory, 0o755)
    target = directory / "log"
    if log is not None and log.exists():
        shutil.move(log, target)
    if message is not None:
        with open(target, "a") as file:
            file.write(f"\ncoda-ci: {message}\n")
    if target.exists():
        os.chmod(target, 0o644)
    temporary = directory / "status.tmp"
    temporary.write_text(f"{status}\n")
    os.chmod(temporary, 0o644)
    temporary.rename(directory / "status")


def prune(config):
    cutoff = time.time() - RESULT_DAYS * 86400
    for directory in config.results.iterdir():
        if directory.is_dir() and not directory.is_symlink() and directory.stat().st_mtime < cutoff:
            shutil.rmtree(directory)
    logs = sorted(config.logs.glob("github-*.log"), key=lambda path: path.stat().st_mtime)
    for old in logs[:-GITHUB_LOGS_KEPT]:
        old.unlink()


def run_github(config, token, job):
    registration = register(token, job["id"])
    runner_id = registration["runner"]["id"]
    started = time.monotonic()

    def keep_going():
        if time.monotonic() - started < IDLE_GRACE_SECONDS:
            return True
        runner = api(token, f"{RUNNERS_PATH}/{runner_id}")
        if runner["busy"]:
            return True
        return api(token, f"repos/{REPO}/actions/jobs/{int(job['id'])}")["status"] == "queued"

    log = config.logs / f"github-{int(job['id'])}.log"
    try:
        with tempfile.TemporaryDirectory(dir=config.root) as inputs:
            inputs = Path(inputs)
            (inputs / "mode").write_text("github\n")
            (inputs / "jit").write_text(registration["encoded_jit_config"])
            print(f"Running GitHub job {job['id']} ({job['name']})", flush=True)
            status = run_job(config, f"github-{int(job['id'])}", inputs, log, keep_going)
            print(f"GitHub job {job['id']} exited {status}", flush=True)
    finally:
        delete_runner(token, runner_id)


def run_local(config, request_id):
    with tempfile.TemporaryDirectory(dir=config.root) as inputs:
        inputs = Path(inputs)
        try:
            job = claim_request(config.requests, request_id, inputs, config.max_bundle_bytes)
        except RequestRejected as error:
            write_result(config.results, request_id, REJECTED, message=str(error))
            return
        (inputs / "mode").write_text("act\n")
        log = config.root / f"local-{request_id}.log"
        print(f"Running local request {request_id} (act -j {job})", flush=True)
        try:
            status = run_job(config, f"local-{request_id}", inputs, log)
        except GuestFailed as error:
            write_result(config.results, request_id, GUEST_FAILED, log, str(error))
            return
        except BaseException:
            write_result(config.results, request_id, GUEST_FAILED, log, "the controller failed; see its journal")
            raise
        write_result(config.results, request_id, status, log)
        print(f"Local request {request_id} exited {status}", flush=True)


def seed(config):
    """Pull the pinned images into a fresh work disk and make it the seed."""
    job_dir = config.jobs / "seed"
    job_dir.mkdir()
    try:
        with tempfile.TemporaryDirectory(dir=config.root) as inputs:
            inputs = Path(inputs)
            (inputs / "mode").write_text("seed\n")
            make_disk(job_dir / "work.img", config.work_disk_size)
            make_inputs(job_dir / "inputs.img", inputs)
            status = run_guest(config, job_dir, config.logs / "seed.log")
        if status != 0:
            raise GuestFailed(f"seeding exited {status}; see {config.logs / 'seed.log'}")
        config.seed.parent.mkdir(exist_ok=True)
        (job_dir / "work.img").rename(config.seed)
        print(f"New seed at {config.seed}", flush=True)
    finally:
        shutil.rmtree(job_dir)


def read_token():
    credentials = os.environ.get("CREDENTIALS_DIRECTORY")
    path = Path(credentials) / "github-token" if credentials else None
    if path is None or not path.exists():
        return None
    return path.read_text().strip() or None


def one_pass(config, token):
    if token is not None:
        job = next_github_job(token)
        if job is not None:
            if not admit(config):
                print("Not enough memory for a guest; GitHub job waits.", flush=True)
                return
            run_github(config, token, job)
            return
    request_id = next_local_request(config.requests)
    if request_id is None:
        return
    if not admit(config):
        print("Not enough memory for a guest; local request waits.", flush=True)
        return
    run_local(config, request_id)


def main(argv):
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
    config = Config.from_env()
    for directory in (config.jobs, config.results, config.logs):
        directory.mkdir(parents=True, exist_ok=True)
    os.chmod(config.results, 0o755)
    with open(config.root / "lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        token = read_token()
        reconcile(token, config.jobs)
        if argv == ["seed"]:
            seed(config)
            return
        if argv:
            raise SystemExit(f"usage: coda-ci-controller [seed]; got {argv}")
        prune(config)
        one_pass(config, token)


if __name__ == "__main__":
    main(sys.argv[1:])
