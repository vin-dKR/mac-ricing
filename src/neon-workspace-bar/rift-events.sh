#!/bin/bash
set -eu

root=${MAC_RICING_ROOT:-"$HOME/.local/share/mac-ricing/current"}
rift=${MAC_RICING_RIFT_CLI:-rift-cli}
post="$root/bin/post-event.sh"
for event in windows_changed focused_window_changed window_title_changed; do
    "$rift" subscribe cli --event "$event" --command "$post" --args=refresh
done
for event in workspace_changed layout_changed; do
    "$rift" subscribe cli --event "$event" --command "$post" --args=layout
done
"$rift" subscribe cli --event binding_mode_changed --command "$post" --args=mode
"$post" mode
"$post" layout
