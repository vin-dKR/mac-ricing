#!/bin/bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
sandbox=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$sandbox"' EXIT

checkout="$sandbox/Checkout With Spaces"
test_home="$sandbox/Test Home With A Long Path And Spaces"
brew_root="$sandbox/Fake Homebrew"
mkdir -p "$checkout" "$test_home/.config/rift" "$test_home/.rift"     "$brew_root/bin" "$brew_root/opt/rift/Rift.app/Contents/MacOS"
cp -R "$repo/config" "$repo/src" "$repo/scripts" "$repo/assets" "$checkout/"
printf 'existing Rift config\n' > "$test_home/.config/rift/config.toml"
printf 'existing Rift layout\n' > "$test_home/.rift/layout.ron"

cat > "$brew_root/bin/brew" <<'BREW'
#!/bin/bash
set -euo pipefail
if [[ "$#" -eq 1 && "$1" == --prefix ]]; then
    printf '%s\n' "$FIXTURE_BREW_ROOT"
elif [[ "$#" -eq 2 && "$1" == --prefix && "$2" == rift ]]; then
    printf '%s\n' "$FIXTURE_BREW_ROOT/opt/rift"
else
    exit 2
fi
BREW
cat > "$brew_root/opt/rift/Rift.app/Contents/MacOS/rift" <<'RIFT'
#!/bin/bash
if [[ "${1:-}" == --version ]]; then
    printf 'rift %s\n' "${FIXTURE_RIFT_VERSION:-0.8.6}"
else
    exit 2
fi
RIFT
cat > "$brew_root/bin/rift-cli" <<'CLI'
#!/bin/bash
if [[ "${1:-}" == --version ]]; then
    printf 'rift-cli %s\n' "${FIXTURE_RIFT_VERSION:-0.8.6}"
else
    exit 2
fi
CLI
chmod +x "$brew_root/bin/brew" "$brew_root/bin/rift-cli" "$brew_root/opt/rift/Rift.app/Contents/MacOS/rift"
ln -s /usr/bin/true "$brew_root/bin/jq"

export HOME="$test_home" FIXTURE_BREW_ROOT="$brew_root"
export PATH="$brew_root/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
install_root="$HOME/.local/share/mac-ricing"
state_root="$HOME/.local/state/mac-ricing"

"$checkout/scripts/install.sh" --dry-run
[[ ! -e "$install_root" && ! -e "$state_root" && ! -e "$HOME/Library/LaunchAgents" ]]
if FIXTURE_RIFT_VERSION=0.8.5 "$checkout/scripts/install.sh" --no-start 2>/dev/null; then
    echo "An unsupported Rift version was accepted." >&2
    exit 1
fi
[[ ! -e "$install_root" ]]

"$checkout/scripts/install.sh" --no-start
[[ -L "$install_root/current" && ! -e "$HOME/Library/LaunchAgents" ]]
current="$install_root/current"
for app in "Neon Workspace Bar" "Keyboard Desk"; do
    /usr/bin/codesign --verify --strict "$current/Applications/$app.app"
done

python3 - "$current" "$brew_root" "$checkout" <<'PY'
import os
import plistlib
import socket
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

link = Path(sys.argv[1])
current = link.parent.resolve() / link.name
with (current / "config/rift.toml").open("rb") as file:
    config = tomllib.load(file)
assert config["keys"]["Alt + 1"]["exec"] == [str(current / "bin/workspace-request"), "0"]
assert config["keys"]["Alt + Ctrl + S"]["exec"][0] == str((Path(sys.argv[2]) / "bin/rift-cli").resolve())
for name in ("workspace-request", "swap-window.sh", "metrics.sh", "rift-events.sh", "terminal.sh"):
    assert (current / "bin" / name).is_file()
for app in (current / "Applications").glob("*.app"):
    with (app / "Contents/Info.plist").open("rb") as file:
        assert plistlib.load(file)["CFBundleIdentifier"].startswith("io.github.macricing.")

sys.path.insert(0, str(Path(sys.argv[3]) / "scripts"))
import manage

locations = manage.Locations(Path.home().resolve())
dependencies = manage.Dependencies.resolve()
for service in manage.AGENTS:
    job = plistlib.loads(manage.launch_job(locations, dependencies, service))
    assert job["Label"] == f"io.github.macricing.{service}"
    env = job["EnvironmentVariables"]
    assert env["MAC_RICING_ROOT"] == str(current)
    assert env["RIFT_BS_NAME"] == "io.github.macricing.rift.ipc"
    assert len(os.fsencode(env["MAC_RICING_SOCKET"])) < 104
    if service in ("rift", "rift-layout"):
        assert env["HOME"] == str(locations.state / "rift-home")
rift_job = plistlib.loads(manage.launch_job(locations, dependencies, "rift"))
assert rift_job["ProgramArguments"][1:3] == ["--config", str(current / "config/rift.toml")]

with tempfile.TemporaryDirectory(prefix="mac-ricing-", dir="/tmp") as temporary:
    address = str(Path(temporary) / "switch.sock")
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as receiver:
        receiver.bind(address)
        receiver.settimeout(1)
        subprocess.run([current / "bin/workspace-request", "4"],
                       env={**os.environ, "MAC_RICING_SOCKET": address}, check=True)
        timestamp, index = receiver.recv(64).decode().split()
        assert timestamp.isdecimal() and index == "4"
PY

"$checkout/scripts/install.sh" --no-start
[[ -L "$current" && ! -e "$HOME/Library/LaunchAgents" ]]
[[ "$(cat "$HOME/.config/rift/config.toml")" == "existing Rift config" ]]
[[ "$(cat "$HOME/.rift/layout.ron")" == "existing Rift layout" ]]
"$checkout/scripts/uninstall.sh" --dry-run
[[ -L "$current" ]]
"$checkout/scripts/uninstall.sh"
[[ ! -e "$current" ]]
[[ "$(cat "$HOME/.config/rift/config.toml")" == "existing Rift config" ]]
[[ "$(cat "$HOME/.rift/layout.ron")" == "existing Rift layout" ]]
echo "Build, path quoting, isolated lifecycle, and preservation checks passed."
