#!/bin/bash
set -euo pipefail

network_type() {
    local device port
    device=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '$1 == "interface:" { print $2; exit }') || device=''
    if [[ -z "$device" ]]; then
        device=$(/sbin/route -n get -inet6 default 2>/dev/null | /usr/bin/awk '$1 == "interface:" { print $2; exit }') || device=''
    fi
    case "$device" in
        '') printf '%s' Offline; return ;;
        utun[0-9]*|tun[0-9]*|ppp[0-9]*|ipsec[0-9]*) printf '%s' VPN; return ;;
    esac

    port=$(/usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | /usr/bin/awk -v device="$device" '
        /^\(Hardware Port: / && index($0, ", Device: " device ")") {
            sub(/^\(Hardware Port: /, "")
            sub(/, Device: .*$/, "")
            print
            exit
        }') || port=''
    case "$port" in
        Wi-Fi|AirPort) printf '%s' Wi-Fi ;;
        *Ethernet*|*LAN*) printf '%s' Wired ;;
        *) printf '%s' Connected ;;
    esac
}

cpu=$(/usr/sbin/iostat -C -c 2 -w 1 2>/dev/null | /usr/bin/awk '
    { for (i=1; i<=NF; i++) if ($i == "id") idle=i }
    END { if (idle && $idle ~ /^[0-9]+$/) printf "%02d%%", 100 - $idle; else print "--" }
') || cpu=--
total=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null) || total=0
ram=$(/usr/bin/vm_stat | /usr/bin/awk -v total="$total" '
    NR == 1 { for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) page=$i }
    /^Pages (free|inactive|speculative):/ { free += $NF }
    END { if (page && total) printf "%02d%%", 100 * (1 - free * page / total); else print "--" }
') || ram=--
battery=$(/usr/bin/pmset -g batt | /usr/bin/awk '
    /InternalBattery/ { if (match($0, /[0-9]+%/)) print "  ·  BAT " substr($0, RSTART, RLENGTH) }
') || battery=''
printf 'CPU %s  ·  RAM %s  ·  NET %s%s\n' "$cpu" "$ram" "$(network_type)" "$battery"
