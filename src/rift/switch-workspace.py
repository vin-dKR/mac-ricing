#!/usr/bin/env python3
import json
import os
import select
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path


os.environ.setdefault("RIFT_BS_NAME", "io.github.macricing.rift.ipc")
RIFT = os.environ.get("MAC_RICING_RIFT_CLI") or "rift-cli"
CONFIG = Path(__file__).parent
NATIVE_SPACES = CONFIG / "native-space-info"
STATE = Path(os.environ.get("MAC_RICING_STATE") or Path.home() / ".local/state/mac-ricing")
DESKTOP = 0
FULLSCREEN = 4
SELECTIONS = {str(index) for index in range(10)} | {"last", "remember", "left", "right"}


def query(kind, *args):
    return json.loads(subprocess.check_output([RIFT, "query", kind, *args], timeout=0.6))


def current(rows):
    return next((row for row in rows if row["is_focused"]),
                next((row for row in rows if row["is_active"]), None))


def execute(*args):
    subprocess.run([RIFT, "execute", *args], check=True,
                   stdout=subprocess.DEVNULL, timeout=0.6)


def native_spaces():
    try:
        return json.loads(subprocess.check_output([NATIVE_SPACES], timeout=0.45))
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None


def switch_native(requests, snapshot, target):
    """Navigate through macOS Spaces with Rift's adjacent Space command."""
    ordered = [space["id"] for space in snapshot["spaces"]]
    current = snapshot["current"]["id"]
    if current not in ordered or target not in ordered:
        return False
    initial = ordered.index(current)
    final = ordered.index(target)
    step = 1 if final > initial else -1
    for index in range(initial + step, final + step, step):
        if requests.superseded():
            return False
        execute("space", "switch", "right" if step > 0 else "left")
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            current = native_spaces()
            if (current and current["display"] == snapshot["display"]
                    and current["current"]["id"] == ordered[index]):
                break
            if requests.superseded(0.05):
                return False
        else:
            return False
    return True


class WorkspaceRequests:
    def __init__(self, listener):
        self.listener = listener
        self.latest = 0
        self.pending = None

    def receive(self, timeout):
        if not select.select([self.listener], [], [], timeout)[0]:
            return
        while True:
            try:
                stamp, selection = self.listener.recv(64).decode("ascii").split()
                stamp = int(stamp)
            except BlockingIOError:
                return
            except (ValueError, UnicodeError):
                continue
            if stamp > self.latest and selection in SELECTIONS:
                self.latest = stamp
                self.pending = selection

    def superseded(self, timeout=0):
        self.receive(timeout)
        return self.pending is not None

    def wait_for(self, check, timeout):
        deadline = time.monotonic() + timeout
        while self.pending is None:
            if result := check():
                return result
            remaining = deadline - time.monotonic()
            if remaining <= 0 or self.superseded(min(0.016, remaining)):
                return None
        return None

    def next(self):
        while self.pending is None:
            self.receive(None)
        selection = self.pending
        self.pending = None
        return selection


def prepare_desktop(requests, remembered, selection):
    displays = query("displays")
    if len(displays) == 1 and displays[0]["is_active_space"]:
        display = displays[0]
        remembered[display["uuid"]] = display["space"]
        return True

    snapshot = native_spaces()
    if snapshot is None:
        return any(display["is_active_space"] for display in displays)
    uuid = snapshot["display"]
    native = snapshot["current"]
    if native["type"] == DESKTOP:
        if any(display["uuid"] == uuid and display["is_active_space"] for display in displays):
            remembered[uuid] = native["id"]
            return True
        return False
    if selection == "remember" or native["type"] != FULLSCREEN:
        return False

    positions = {space["id"]: i for i, space in enumerate(snapshot["spaces"])}
    desktops = [space["id"] for space in snapshot["spaces"] if space["type"] == DESKTOP]
    if not desktops or native["id"] not in positions or requests.superseded():
        return False
    preferred = remembered.get(uuid)
    target = preferred if preferred in desktops else min(
        desktops, key=lambda desktop: abs(positions[desktop] - positions[native["id"]]))
    if not switch_native(requests, snapshot, target):
        # A newly created fullscreen Space can change the display's inventory
        # between the snapshot and the direct switch. Refresh once.
        latest = native_spaces()
        if (requests.superseded() or not latest or latest["display"] != uuid
                or latest["current"]["id"] not in (native["id"], target)
                or not switch_native(requests, latest, target)):
            return False

    def rift_ready():
        return any(display["uuid"] == uuid and display["space"] == target and display["is_active_space"]
                   for display in query("displays"))

    if requests.wait_for(rift_ready, 0.32):
        remembered[uuid] = target
        return True
    return False


def select_workspace(requests, remembered, selection):
    if selection in ("left", "right"):
        if not requests.superseded():
            execute("space", "switch", selection)
        return

    if not prepare_desktop(requests, remembered, selection) or selection == "remember":
        return
    if selection == "last":
        if not requests.superseded():
            execute("workspace", "last")
        return

    rows = query("workspaces")
    origin = current(rows)
    target = next((row for row in rows if row["index"] == int(selection)), None)
    if origin and target and origin["id"] == target["id"]:
        return
    if requests.superseded():
        return
    execute("workspace", "switch", selection)

    if origin and target and target["window_count"] == 0 and not requests.superseded(0.20):
        # macOS can briefly reactivate the outgoing app when no window takes focus.
        # Retry only if that happened and no more recent request is waiting.
        selected = current(query("workspaces"))
        if selected and selected["id"] == origin["id"] and not requests.superseded():
            execute("workspace", "switch", selection)


def serve():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    socket_path = Path(os.environ.get("MAC_RICING_SOCKET") or STATE / "switch.sock")
    if not socket_path.is_absolute() or len(os.fsencode(socket_path)) >= 104:
        raise ValueError("The workspace socket needs an absolute path shorter than 104 bytes")
    socket_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = socket_path.parent.stat(follow_symlinks=False)
    if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.getuid() or directory.st_mode & 0o077:
        raise ValueError("The workspace socket directory must be owned by the current user and private")
    state_path = STATE / "workspace-switch"
    try:
        remembered = json.loads(state_path.read_text()).get("desktops", {})
    except (AttributeError, ValueError, OSError):
        remembered = {}
    if not isinstance(remembered, dict):
        remembered = {}

    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
        listener.setblocking(False)
        try:
            previous_socket = socket_path.lstat()
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISSOCK(previous_socket.st_mode) or previous_socket.st_uid != os.getuid():
                raise ValueError("The workspace socket path is occupied by an unrelated file")
            socket_path.unlink()
        listener.bind(str(socket_path))
        socket_path.chmod(0o600)
        requests = WorkspaceRequests(listener)

        while True:
            selection = requests.next()
            before = remembered.copy()
            try:
                select_workspace(requests, remembered, selection)
                if remembered != before:
                    temp_path = state_path.with_suffix(".tmp")
                    temp_path.write_text(json.dumps({"desktops": remembered}))
                    temp_path.replace(state_path)
            except (OSError, subprocess.SubprocessError, ValueError) as error:
                print(f"Workspace {selection}: {error}", file=sys.stderr)


if __name__ == "__main__":
    if sys.argv[1:] == ["--serve"]:
        serve()
    else:
        os.execv(CONFIG / "workspace-request", ["workspace-request", *sys.argv[1:]])
