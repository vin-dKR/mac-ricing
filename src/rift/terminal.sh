#!/bin/sh
set -eu
if /usr/bin/open -b com.mitchellh.ghostty 2>/dev/null; then
    exit
fi
exec /usr/bin/open -b com.apple.Terminal
