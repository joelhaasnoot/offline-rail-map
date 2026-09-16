#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# Captures the raw store screenshots from a running emulator or device over adb. The app must be
# installed with the Netherlands pack; the Countries shot lists whatever manifest the build reads.
# The display is switched to 1080x1920 (Play rejects screenshots longer than 2:1) with a clean
# demo-mode status bar, and restored afterwards. Frame them with make_store_assets.py.
#
# Usage: [FROM=<n>] take_screenshots.sh [output dir]   (default: pipeline/work/screenshots/phone)
set -euo pipefail

OUT="${1:-$(dirname "$0")/work/screenshots/phone}"
APP=com.offlinerailmap.android
mkdir -p "$OUT"

# Other tools (Android Studio) can restart the adb server mid-run, which briefly reports the device as
# "still authorizing"; wait for it and retry the command once.
adb() {
    command adb "$@" || { command adb wait-for-device && sleep 2 && command adb "$@"; }
}

demo() {
    adb shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null
}

restore() {
    demo exit || true
    adb shell wm size reset || true
}
trap restore EXIT

adb shell wm size 1080x1920
adb shell settings put global sysui_demo_allowed 1
demo enter
demo clock -e hhmm 0930
demo battery -e level 100 -e plugged false
demo network -e wifi show -e level 4 -e mobile hide
demo notifications -e visible false

# Centre of the on-screen element whose text or content description is exactly $1, if any.
find_node() {
    adb shell rm -f /sdcard/ui.xml
    # The dump fails now and then ("null root node") while the map is busy.
    for _ in 1 2 3 4 5; do
        if adb shell uiautomator dump /sdcard/ui.xml | grep -q dumped; then
            break
        fi
        sleep 1
    done
    adb exec-out cat /sdcard/ui.xml | python3 -c '
import re, sys
label = sys.argv[1]
for node in re.findall(r"<node [^>]*>", sys.stdin.read()):
    if re.search(r"(text|content-desc)=\"" + re.escape(label) + "\"", node):
        l, t, r, b = map(int, re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", node).groups())
        print((l + r) // 2, (t + b) // 2)
        break
' "$1"
}

# Taps a label, scrolling the row of view chips sideways when it is off screen.
tap() {
    local pos
    for attempt in 1 2; do
        for swipe in "" "1000 137 200 137" "80 137 880 137"; do
            if [ -n "$swipe" ]; then
                # A quick swipe is sometimes lost; a slow one scrolls the row reliably.
                adb shell input swipe $swipe 600
                sleep 2
            fi
            pos=$(find_node "$1")
            if [ -n "$pos" ]; then
                adb shell input tap $pos
                return
            fi
        done
        # A slow emulator can raise an "isn't responding" dialog over the app; let it keep running.
        pos=$(find_node Wait)
        if [ "$attempt" = 1 ] && [ -n "$pos" ]; then
            echo "dismissing an app-not-responding dialog" >&2
            adb shell input tap $pos
            settle 5
        else
            break
        fi
    done
    echo "could not find \"$1\" on screen" >&2
    exit 1
}

# Waits until three consecutive frames are identical: the camera has stopped and tiles are drawn.
# Tiles can pause for a moment between loading and drawing, so one matching pair is not enough.
settle() {
    local prev="" cur same=0
    sleep "${1:-2}"
    for _ in $(seq 1 30); do
        cur=$(adb exec-out screencap | shasum | cut -d' ' -f1) || cur=""
        if [ "$cur" = "$prev" ]; then
            same=$((same + 1))
            if [ "$same" -ge 2 ]; then
                return
            fi
        else
            same=0
        fi
        prev=$cur
        sleep 1.5
    done
    echo "screen did not settle, capturing anyway" >&2
}

# Switching views rebuilds the style off the main thread, so the old map stays still for a moment.
view() {
    tap "$1"
    settle 6
}

camera() {
    adb shell am start -n "$APP/.MainActivity" -a android.intent.action.VIEW -d "'geo:$1,$2?z=$3'" >/dev/null 2>&1
    settle 5
}

shot() {
    adb exec-out screencap -p > "$OUT/$1.png"
    echo "captured $1"
}

# FROM=<n> resumes at shot n, keeping earlier captures.
from="${FROM:-1}"
wanted() {
    [ "$1" -ge "$from" ]
}

adb shell am force-stop "$APP"
adb shell am start -n "$APP/.MainActivity" >/dev/null
settle 6

if wanted 1; then
    view Infrastructure
    camera 52.0905 5.1110 13.4       # Utrecht Centraal
    shot 1_infrastructure
fi

if wanted 2; then
    view "Train protection"
    camera 52.3790 4.9000 16.6       # east of Amsterdam Centraal
    shot 2_train_protection
fi

if wanted 3; then
    view Speed
    camera 52.30 4.93 11.2           # Amsterdam Zuidoost
    shot 3_speed
fi

if wanted 4; then
    view Electrification
    camera 51.90 4.95 8.7            # HSL-Zuid and Betuweroute (25 kV) among 1.5 kV lines
    shot 4_electrification
fi

if wanted 5; then
    view Operator
    camera 52.10 5.00 8.7
    shot 5_operator
fi

if wanted 6 || wanted 7; then
    view "Train protection"
    camera 52.3790 4.9000 16.6
    tap "Key, map settings and countries"
    settle 4
fi
if wanted 6; then
    shot 6_key
fi

if wanted 7; then
    tap Countries
    settle 4
    shot 7_countries
fi

adb shell input keyevent BACK
