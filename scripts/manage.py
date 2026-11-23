"""Build and manage the user-owned mac-ricing installation."""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib


REPO = Path(__file__).resolve().parent.parent
PREFIX = "io.github.macricing"
RIFT_VERSION = "0.8.6"
MARKER = ".mac-ricing-managed"
MANAGED_VERSION = b"mac-ricing-install-v1\n"
AGENTS = ("rift-workspaces", "rift", "neon-workspace-bar", "keyboard-desk", "rift-layout")
LAUNCHCTL = "/bin/launchctl"


class InstallError(Exception):
    pass


def run(*args, capture=False, check=True):
    return subprocess.run(
        args,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def checked_path(path):
    resolved = Path(path).expanduser().resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise InstallError(f"Missing executable at {resolved}")
    return resolved


@dataclass(frozen=True)
class Dependencies:
    brew_prefix: Path
    rift: Path
    rift_cli: Path

    @classmethod
    def resolve(cls):
        if sys.platform != "darwin":
            raise InstallError("This release requires macOS 26 Tahoe or later.")
        major = int(run("/usr/bin/sw_vers", "-productVersion", capture=True).stdout.split(".")[0])
        if major < 26:
            raise InstallError("This release requires macOS 26 Tahoe or later.")
        brew = shutil.which("brew")
        if not brew:
            brew = next((path for path in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew")
                         if Path(path).is_file()), None)
        if not brew:
            raise InstallError("Install Homebrew before running the installer.")
        brew_prefix = Path(run(brew, "--prefix", capture=True).stdout.strip())
        checked_path(brew_prefix / "bin/jq")
        for tool in ("swiftc", "clang"):
            if run("/usr/bin/xcrun", "--find", tool, capture=True, check=False).returncode:
                raise InstallError("Install the Xcode Command Line Tools with xcode-select --install.")
        app_override = os.environ.get("MAC_RICING_RIFT_APP")
        cli_override = os.environ.get("MAC_RICING_RIFT_CLI")
        if bool(app_override) != bool(cli_override):
            raise InstallError("Set both MAC_RICING_RIFT_APP and MAC_RICING_RIFT_CLI, or leave both unset.")
        if app_override:
            app_path = Path(app_override)
            cli_path = Path(cli_override)
            if not app_path.is_absolute() or not cli_path.is_absolute() or app_path.suffix != ".app":
                raise InstallError("Use absolute paths to Rift.app and the rift-cli executable.")
        else:
            formula = run(brew, "--prefix", "rift", capture=True, check=False)
            if formula.returncode:
                raise InstallError("Install acsandmann/tap/rift with Homebrew.")
            app_path = Path(formula.stdout.strip()) / "Rift.app"
            cli_path = brew_prefix / "bin/rift-cli"
        rift = checked_path(app_path / "Contents/MacOS/rift")
        cli = checked_path(cli_path)
        for executable, name in ((rift, "rift"), (cli, "rift-cli")):
            version = run(executable, "--version", capture=True).stdout.strip()
            if version != f"{name} {RIFT_VERSION}":
                raise InstallError(f"The supported {name} version is {RIFT_VERSION}. Found {version!r}.")
        return cls(brew_prefix=brew_prefix, rift=rift, rift_cli=cli)


@dataclass(frozen=True)
class Locations:
    home: Path

    @property
    def root(self):
        return self.home / ".local/share/mac-ricing"

    @property
    def state(self):
        return self.home / ".local/state/mac-ricing"

    @property
    def rift_home(self):
        return self.state / "rift-home"

    @property
    def current(self):
        return self.root / "current"

    @property
    def socket_path(self):
        socket = self.state / "switch.sock"
        if len(os.fsencode(socket)) < 104:
            return socket
        temporary = Path(run("/usr/bin/getconf", "DARWIN_USER_TEMP_DIR", capture=True).stdout.strip())
        key = hashlib.sha256(os.fsencode(self.home)).hexdigest()[:12]
        socket = temporary / f"mac-ricing-{key}" / "switch.sock"
        if not socket.is_absolute() or len(os.fsencode(socket)) >= 104:
            raise InstallError("The per-user temporary directory is too long for a macOS socket.")
        return socket

    @property
    def agents(self):
        return self.home / "Library/LaunchAgents"

    @property
    def session(self):
        return f"gui/{os.getuid()}"

    @property
    def is_login_home(self):
        try:
            return self.home == Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
        except KeyError:
            return False

    def plist(self, service):
        return self.agents / f"{PREFIX}.{service}.plist"

    def target(self, service):
        return f"{self.session}/{PREFIX}.{service}"


def ensure_owned(directory, create=False):
    if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
        raise InstallError(f"Refusing to manage the existing path {directory}")
    marker = directory / MARKER
    if directory.exists() and any(directory.iterdir()):
        if marker.is_symlink() or not marker.is_file() or marker.read_bytes() != MANAGED_VERSION:
            raise InstallError(f"Refusing to modify unrecognized contents in {directory}")
    if create:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory.chmod(0o700)
        marker.write_bytes(MANAGED_VERSION)


def current_release(locations):
    link = locations.current
    if not link.is_symlink():
        if link.exists():
            raise InstallError(f"Refusing to replace the existing path {link}")
        return None
    target = os.readlink(link)
    # Only version directories created underneath the managed root are eligible.
    if not re.fullmatch(r"release-[a-z0-9_]+", target):
        raise InstallError(f"Refusing to change an unrecognized current release link: {link}")
    version = locations.root / target
    marker = version / MARKER
    if (version.is_symlink() or not version.is_dir() or marker.is_symlink()
            or not marker.is_file() or marker.read_bytes() != MANAGED_VERSION):
        raise InstallError(f"Current release is missing its ownership marker: {version}")
    return target


def replace_current(locations, release):
    link = locations.current
    if release is None:
        link.unlink(missing_ok=True)
        return
    with tempfile.TemporaryDirectory(prefix=".switch-", dir=locations.root) as temporary:
        next_link = Path(temporary) / "current"
        next_link.symlink_to(release, target_is_directory=True)
        os.replace(next_link, link)


def check_home(paths, require_login_home):
    if os.getuid() == 0:
        raise InstallError("Run as the logged-in user, without sudo.")
    if require_login_home and not paths.is_login_home:
        raise InstallError("Use your login home for LaunchAgent installation or pass --no-start.")


def job_state(paths, service):
    return run(LAUNCHCTL, "print", paths.target(service), capture=True, check=False)


def existing_jobs(paths):
    jobs = {}
    for service in AGENTS:
        plist = paths.plist(service)
        if plist.is_symlink():
            raise InstallError(f"Refusing to replace the unrelated login job {plist}")
        if not plist.exists():
            continue
        try:
            data = plist.read_bytes()
            parsed = plistlib.loads(data)
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            raise InstallError(f"Refusing to change unrecognized login job {plist}") from error
        if (parsed.get("Label") != f"{PREFIX}.{service}"
                or parsed.get("EnvironmentVariables", {}).get("MAC_RICING_ROOT") != str(paths.current)):
            raise InstallError(f"Refusing to replace the unrelated login job {plist}")
        jobs[service] = data
    return jobs


def check_sessions(paths, jobs):
    if run(LAUNCHCTL, "print", paths.session, capture=True, check=False).returncode:
        raise InstallError("No interactive macOS session found. Sign in locally or pass --no-start.")

    loaded = set()
    managed_rift_pid = None
    for service in AGENTS:
        status = job_state(paths, service)
        if status.returncode:
            continue
        if service not in jobs:
            raise InstallError(f"Unrecognized launchd job is already loaded: {paths.target(service)}")
        loaded.add(service)
        if service == "rift":
            own_pid = re.search(r"^\s*pid = (\d+)\s*$", status.stdout, re.MULTILINE)
            managed_rift_pid = own_pid.group(1) if own_pid else None

    legacy = "git.acsandmann.rift"
    if run(LAUNCHCTL, "print", f"{paths.session}/{legacy}", capture=True, check=False).returncode == 0:
        raise InstallError("An existing Rift LaunchAgent is running. Stop it through its own service manager first.")
    legacy_job = paths.agents / f"{legacy}.plist"
    if legacy_job.exists():
        disabled = run(LAUNCHCTL, "print-disabled", paths.session, capture=True, check=False).stdout
        if not re.search(rf'"{re.escape(legacy)}"\s*=>\s*(?:disabled|true)\b', disabled):
            raise InstallError("An existing Rift LaunchAgent would start at login. Disable it manually first.")

    for name in ("rift", "AeroSpace", "aerospace", "yabai", "Amethyst", "OmniWM"):
        processes = run("/usr/bin/pgrep", "-U", str(os.getuid()), "-x", name, capture=True, check=False)
        if any(pid != managed_rift_pid for pid in processes.stdout.split()):
            raise InstallError(f"{name} is already running. Quit it before enabling mac-ricing.")
    return loaded


def bootstrap(paths, service):
    result = run(LAUNCHCTL, "bootstrap", paths.session, paths.plist(service), capture=True, check=False)
    if result.returncode:
        raise InstallError(f"Could not start {paths.target(service)}: {result.stderr.strip()}")


def bootout(paths, service):
    result = run(LAUNCHCTL, "bootout", paths.target(service), capture=True, check=False)
    if result.returncode:
        raise InstallError(f"Could not stop {paths.target(service)}: {result.stderr.strip()}")


def atomic_write(path, data):
    descriptor, name = tempfile.mkstemp(prefix=".mac-ricing-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def launch_environment(paths, dependencies):
    return {
        "MAC_RICING_ROOT": str(paths.current),
        "MAC_RICING_STATE": str(paths.state),
        "MAC_RICING_RIFT_CLI": str(dependencies.rift_cli),
        "MAC_RICING_PYTHON": sys.executable,
        "MAC_RICING_SOCKET": str(paths.socket_path),
        "PATH": f"{paths.current / 'bin'}:{dependencies.brew_prefix / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin",
        "RIFT_BS_NAME": f"{PREFIX}.rift.ipc",
    }


def launch_job(paths, dependencies, service):
    current = paths.current
    bin_path = current / "bin"
    applications = current / "Applications"
    environment = launch_environment(paths, dependencies)
    job = {
        "Label": f"{PREFIX}.{service}",
        "LimitLoadToSessionType": "Aqua",
        "EnvironmentVariables": environment,
        "StandardErrorPath": str(paths.state / f"{service}.log"),
        "WorkingDirectory": str(paths.home),
    }
    if service == "rift-workspaces":
        arguments = [sys.executable, bin_path / "switch-workspace.py", "--serve"]
        job.update(RunAtLoad=True, KeepAlive=True, ProcessType="Interactive")
    elif service == "rift":
        arguments = [dependencies.rift, "--config", current / "config/rift.toml", "--no-animate", "--restore"]
        environment.update(HOME=str(paths.rift_home), RUST_LOG="warn")
        # Rift creates its own bootstrap service. A second server would conflict with it.
        job.update(RunAtLoad=True, KeepAlive={"SuccessfulExit": False}, ProcessType="Interactive",
                   StandardOutPath=str(paths.state / "rift-output.log"))
    elif service == "rift-layout":
        arguments = [dependencies.rift_cli, "execute", "save-layout", "--master"]
        environment["HOME"] = str(paths.rift_home)
        job["StartInterval"] = 120
    elif service == "neon-workspace-bar":
        arguments = [applications / "Neon Workspace Bar.app/Contents/MacOS/NeonWorkspaceBar"]
        job.update(RunAtLoad=True, KeepAlive=True, ProcessType="Interactive")
    else:
        arguments = [applications / "Keyboard Desk.app/Contents/MacOS/KeyboardDesk"]
        job.update(RunAtLoad=True, KeepAlive={"SuccessfulExit": False})
    job["ProgramArguments"] = list(map(str, arguments))
    return plistlib.dumps(job)


def render_config(destination, paths, dependencies):
    template = (REPO / "config/rift.toml.in").read_text()
    values = {
        "@BIN@": paths.current / "bin",
        "@BREW_PREFIX@": dependencies.brew_prefix,
        "@RIFT_CLI@": dependencies.rift_cli,
    }
    for token, value in values.items():
        template = template.replace(token, json.dumps(str(value), ensure_ascii=False)[1:-1])
    tomllib.loads(template)
    destination.write_text(template)


def build_app(source, applications, title, executable):
    app = applications / f"{title}.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    macos.mkdir(parents=True)
    shutil.copy2(source / "Info.plist", contents / "Info.plist")
    run("/usr/bin/xcrun", "swiftc", "-O", "-warnings-as-errors",
        *sorted(source.glob("*.swift")), "-o", macos / executable)
    run("/usr/bin/codesign", "--force", "--sign", "-", app)
    run("/usr/bin/codesign", "--verify", "--strict", app)


def build_release(release, paths, dependencies):
    source = REPO / "src"
    bin_path = release / "bin"
    share = release / "share"
    config = release / "config"
    for directory in (bin_path, share, config):
        directory.mkdir()
    for folder in (source / "rift", source / "neon-workspace-bar"):
        for helper in sorted(folder.glob("*.sh")) + sorted(folder.glob("*.py")):
            target = bin_path / helper.name
            shutil.copy2(helper, target)
            target.chmod(0o755)
    render_config(config / "rift.toml", paths, dependencies)
    shutil.copy2(REPO / "config/Shortcuts.txt", share / "Shortcuts.txt")
    for wallpaper in sorted((REPO / "assets/wallpapers").glob("*.png")):
        shutil.copy2(wallpaper, share / wallpaper.name)
    run("/usr/bin/xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror",
        source / "rift/workspace-request.c", "-o", bin_path / "workspace-request")
    run("/usr/bin/xcrun", "swiftc", "-O", "-warnings-as-errors",
        source / "rift/native-space-info.swift", "-o", bin_path / "native-space-info")
    build_app(source / "neon-workspace-bar", release / "Applications", "Neon Workspace Bar", "NeonWorkspaceBar")
    build_app(source / "keyboard-desk", release / "Applications", "Keyboard Desk", "KeyboardDesk")
    (release / MARKER).write_bytes(MANAGED_VERSION)


@contextmanager
def locked_install(paths):
    ensure_owned(paths.root, create=True)
    lock = paths.root / ".lock"
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+b") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise InstallError("Another mac-ricing installation operation is running.") from error
        yield


def activate_release(paths, dependencies, release, previous, jobs, loaded):
    paths.agents.mkdir(parents=True, exist_ok=True)
    stopped = []
    started = []
    written = []
    published = False
    try:
        for service in reversed(AGENTS):
            if service in loaded:
                bootout(paths, service)
                stopped.append(service)
        replace_current(paths, release.name)
        published = True
        for service in AGENTS:
            atomic_write(paths.plist(service), launch_job(paths, dependencies, service))
            written.append(service)
            bootstrap(paths, service)
            started.append(service)
    except (InstallError, OSError, subprocess.SubprocessError, KeyboardInterrupt):
        try:
            for service in reversed(started):
                bootout(paths, service)
            if published:
                replace_current(paths, previous)
            for service in written:
                if service in jobs:
                    atomic_write(paths.plist(service), jobs[service])
                else:
                    paths.plist(service).unlink(missing_ok=True)
            for service in reversed(stopped):
                bootstrap(paths, service)
        except (InstallError, OSError) as rollback:
            print(f"Could not completely roll back: {rollback}", file=sys.stderr)
        raise


def prune_releases(paths, keep):
    for version in paths.root.glob("release-*"):
        if version.name in keep or version.is_symlink() or not version.is_dir():
            continue
        marker = version / MARKER
        if marker.is_file() and not marker.is_symlink() and marker.read_bytes() == MANAGED_VERSION:
            shutil.rmtree(version)


def install(paths, args):
    check_home(paths, require_login_home=not args.no_start and not args.dry_run)
    dependencies = Dependencies.resolve()
    ensure_owned(paths.root)
    ensure_owned(paths.state)
    current_release(paths)
    jobs = existing_jobs(paths)
    if args.no_start and jobs:
        raise InstallError("Existing mac-ricing login jobs are present. Run a normal install to update them together.")
    if args.dry_run:
        print(f"Would build mac-ricing under {paths.root} with Rift {RIFT_VERSION}.")
        if args.no_start:
            print("No launch agents would be installed.")
        else:
            print(f"Would check for competing tilers and manage only {PREFIX} jobs in {paths.agents}.")
        return

    with locked_install(paths):
        jobs = existing_jobs(paths)
        if args.no_start and jobs:
            raise InstallError("Existing mac-ricing login jobs are present. Run a normal install to update them together.")
        loaded = set() if args.no_start else check_sessions(paths, jobs)
        previous = current_release(paths)
        ensure_owned(paths.state, create=True)
        (paths.rift_home / ".rift").mkdir(mode=0o700, parents=True, exist_ok=True)
        release = Path(tempfile.mkdtemp(prefix="release-", dir=paths.root))
        try:
            build_release(release, paths, dependencies)
            if args.no_start:
                replace_current(paths, release.name)
            else:
                activate_release(paths, dependencies, release, previous, jobs, loaded)
        except BaseException:
            if not paths.current.is_symlink() or os.readlink(paths.current) != release.name:
                shutil.rmtree(release)
            raise
        prune_releases(paths, {release.name, previous})
    print(f"Installed mac-ricing at {paths.current}.")
    if args.no_start:
        print("LaunchAgents were not installed or started. Run the installer normally to enable login startup.")
    else:
        print(f"If Rift requests Accessibility access, allow the official Rift app at {dependencies.rift.parents[2]}.")


def uninstall(paths, args):
    check_home(paths, require_login_home=False)
    ensure_owned(paths.root)
    current_release(paths)
    jobs = existing_jobs(paths)
    if args.dry_run:
        print(f"Would remove the managed apps, helpers and login jobs under {paths.root}.")
        print(f"Saved layouts and logs would remain under {paths.state}.")
        return
    if jobs and not paths.is_login_home:
        raise InstallError("Login jobs may be unloaded only from the logged-in user's home.")
    if not paths.root.exists():
        if jobs:
            raise InstallError("Login jobs exist but their managed install directory is missing.")
        print("mac-ricing is not installed.")
        return
    with locked_install(paths):
        for service in reversed(AGENTS):
            if service not in jobs:
                continue
            if job_state(paths, service).returncode == 0:
                bootout(paths, service)
            paths.plist(service).unlink()
        replace_current(paths, None)
        prune_releases(paths, set())
    print(f"Removed mac-ricing. Saved layouts and logs remain at {paths.state}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("install")
    setup.add_argument("--dry-run", action="store_true", help="check prerequisites and report changes without writing")
    setup.add_argument("--no-start", action="store_true", help="build and install files without creating login jobs")
    removal = commands.add_parser("uninstall")
    removal.add_argument("--dry-run", action="store_true", help="report what would be removed without writing")
    args = parser.parse_args()
    try:
        paths = Locations(Path.home().resolve())
        if args.command == "install":
            install(paths, args)
        else:
            uninstall(paths, args)
    except (InstallError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"mac-ricing: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("mac-ricing: operation interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
