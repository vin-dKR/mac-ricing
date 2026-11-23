#!/bin/bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
for candidate in "$(command -v python3 || true)" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [[ -n "$candidate" && -x "$candidate" ]] &&
        "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
        exec "$candidate" "$script_dir/manage.py" "$@"
    fi
done
printf 'Python 3.11 or newer is required. Install it with Homebrew and run this script again.\n' >&2
exit 1
