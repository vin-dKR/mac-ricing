#!/bin/bash
set -eu
domain="gui/$(/usr/bin/id -u)"
/bin/launchctl kickstart -k "$domain/io.github.macricing.neon-workspace-bar"
