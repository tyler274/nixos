"""Boot a built Cyrene VM, require the Wayland SDDM greeter, save evidence."""

import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

vm = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=False)
(out / "shared").mkdir()
env = os.environ | {
    "NIX_DISK_IMAGE": str(out / "disk.qcow2"),
    "SHARED_DIR": str(out / "shared"),
    "QEMU_OPTS": f"-display none -qmp unix:{out}/qmp.sock,server,nowait "
    f"-serial file:{out}/serial.log -chardev socket,path={out}/ga.sock,server=on,wait=off,id=ga0 "
    "-device virtio-serial -device virtserialport,chardev=ga0,name=org.qemu.guest_agent.0",
}


class Channel:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(15)
        self.sock.connect(str(path))
        self.file = self.sock.makefile("rw")

    def command(self, name, **args):
        self.file.write(json.dumps({"execute": name, "arguments": args}) + "\n")
        self.file.flush()
        while True:
            reply = json.loads(self.file.readline())
            if "error" in reply:
                raise RuntimeError(reply)
            if "return" in reply:
                return reply["return"]

    def close(self):
        self.file.close()
        self.sock.close()


def guest(command):
    channel = Channel(out / "ga.sock")
    try:
        channel.command("guest-sync", id=42)
        pid = channel.command("guest-exec", path="/run/current-system/sw/bin/bash",
                              arg=["-c", "export PATH=/run/current-system/sw/bin:$PATH; " + command],
                              **{"capture-output": True})["pid"]
        end = time.monotonic() + 60
        while time.monotonic() < end:
            result = channel.command("guest-exec-status", pid=pid)
            if result["exited"]:
                text = "".join(base64.b64decode(result.get(k, "")).decode(errors="replace")
                               for k in ("out-data", "err-data"))
                return result.get("exitcode", -1), text
            time.sleep(1)
        raise TimeoutError("Guest command exceeded 60s")
    finally:
        channel.close()


with (out / "qemu.log").open("w") as log:
    process = subprocess.Popen([str(vm / "bin/run-Cyrene-vm")], env=env, stdout=log, stderr=log,
                               start_new_session=True)
    qmp = None
    try:
        deadline = time.monotonic() + 600
        check = """
set -eu
systemctl is-active --quiet graphical.target
systemctl is-active --quiet display-manager.service
pgrep -u sddm -f sddm-greeter >/dev/null
pgrep -u sddm -f kwin_wayland >/dev/null
found=0
for session in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
  if [ "$(loginctl show-session "$session" -p Class --value)" = greeter ]; then
    loginctl show-session "$session" -p Class -p Type -p State -p Name
    test "$(loginctl show-session "$session" -p Type --value)" = wayland
    test "$(loginctl show-session "$session" -p State --value)" = active
    found=1
  fi
done
test "$found" = 1
stat -c '%U %G %a' /home/luluco/.cache | grep -x 'luluco users 700'
! journalctl -b -k --no-pager | grep -q 'Out of memory: Killed process'
"""
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"QEMU exited: {process.returncode}")
            try:
                code, text = guest(check)
                if code == 0:
                    # Require a second successful sample, not a briefly live greeter.
                    time.sleep(10)
                    code, text = guest(check)
                    if code == 0:
                        (out / "login-check.txt").write_text(text)
                        break
            except (OSError, ValueError, RuntimeError, TimeoutError):
                pass
            time.sleep(5)
        else:
            raise TimeoutError("No active Wayland SDDM greeter within 10 minutes")
        qmp = Channel(out / "qmp.sock")
        json.loads(qmp.file.readline())
        qmp.command("qmp_capabilities")
        qmp.command("screendump", filename=str(out / "greeter.png"), format="png")
        print(f"PASS: active Wayland KDE login greeter; evidence: {out}")
    finally:
        try:
            code, text = guest("journalctl -b --no-pager; systemctl --failed --no-pager")
            (out / "journal.txt").write_text(text)
        except Exception as error:
            (out / "diagnostic-error.txt").write_text(str(error))
        if qmp is not None:
            try:
                qmp.command("quit")
            finally:
                qmp.close()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            import signal
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=20)
