#!/bin/sh
set -eu
exec /usr/bin/notifyutil -z 0 -p "io.github.macricing.neon-workspace-bar.$1"
