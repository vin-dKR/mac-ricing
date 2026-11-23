#!/bin/bash
set -euo pipefail

rift=${MAC_RICING_RIFT_CLI:-rift-cli}
pair=$("$rift" query windows | jq -r '
    map(select(.is_floating == false)) | sort_by(.layout_position) as $windows
    | if length < 2 then empty else
        (map(.is_focused) | index(true)) as $focused
        | select($focused != null)
        | [$windows[$focused].id, $windows[($focused + 1) % length].id]
        | map(if type == "string" then . else tojson end) | @tsv
      end
')
if [[ -n "$pair" ]]; then
    IFS=$'\t' read -r first second <<< "$pair"
    "$rift" execute layout swap-windows "$first" "$second"
fi
