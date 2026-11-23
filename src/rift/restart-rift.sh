#!/bin/bash
set -eu
rift=${MAC_RICING_RIFT_CLI:-rift-cli}
"$rift" execute save-layout --master >/dev/null
/bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/io.github.macricing.rift"
