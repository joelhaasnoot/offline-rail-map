#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
#
# Captures the raw App Store screenshots of the iOS app on a simulator, the same shots as
# take_screenshots.sh takes of the Android app. The debug build must be installed on the simulator
# with the Netherlands pack. The simulator cannot be tapped from a script, so each shot relaunches the
# app with launch arguments: the view and camera override the saved preferences (UserDefaults), and
# -screenshotSheet opens the key or the country list. The status bar shows 9:41 with full bars.
# Frame the captures with make_store_assets.py --platform ios.
#
# Usage: [DEVICE=<simulator>] [FROM=<n>] take_ios_screenshots.sh [output dir]
#        (defaults: iPhone 17 Pro Max, the 6.9" size App Store Connect requires; pipeline/work/screenshots/ios)
set -euo pipefail

OUT="${1:-$(dirname "$0")/work/screenshots/ios}"
DEVICE="${DEVICE:-iPhone 17 Pro Max}"
APP=com.offlinerailmap.ios
mkdir -p "$OUT"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" >/dev/null

if ! xcrun simctl get_app_container "$DEVICE" "$APP" >/dev/null 2>&1; then
    echo "$APP is not installed on $DEVICE; build and install the debug build first" >&2
    exit 1
fi

restore() {
    xcrun simctl status_bar "$DEVICE" clear || true
}
trap restore EXIT
xcrun simctl status_bar "$DEVICE" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

# Waits until three consecutive captures are identical: the camera has stopped and tiles are drawn.
settle() {
    local prev="" cur same=0 tmp
    tmp=$(mktemp -t railmap-shot).png
    sleep "${1:-4}"
    for _ in $(seq 1 30); do
        xcrun simctl io "$DEVICE" screenshot "$tmp" >/dev/null 2>&1
        cur=$(shasum "$tmp" | cut -d' ' -f1)
        if [ "$cur" = "$prev" ]; then
            same=$((same + 1))
            if [ "$same" -ge 2 ]; then
                rm -f "$tmp"
                return
            fi
        else
            same=0
        fi
        prev=$cur
        sleep 1.5
    done
    rm -f "$tmp"
    echo "screen did not settle, capturing anyway" >&2
}

# shot <name> <view> <lat> <lon> <zoom> [sheet tab]
shot() {
    local name=$1 mode=$2 lat=$3 lon=$4 zoom=$5 sheet=${6:-}
    local args=(-mode "$mode" -cam_lat "$lat" -cam_lon "$lon" -cam_zoom "$zoom")
    if [ -n "$sheet" ]; then
        args+=(-screenshotSheet "$sheet")
    fi
    xcrun simctl terminate "$DEVICE" "$APP" 2>/dev/null || true
    xcrun simctl launch "$DEVICE" "$APP" "${args[@]}" >/dev/null
    # With a sheet, wait for the app to open it (8 s) before looking for a still screen.
    settle "$([ -n "$sheet" ] && echo 12 || echo 6)"
    xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png" >/dev/null 2>&1
    echo "captured $name"
}

# FROM=<n> resumes at shot n, keeping earlier captures.
from="${FROM:-1}"
wanted() {
    [ "$1" -ge "$from" ]
}

wanted 1 && shot 1_infrastructure standard 52.0905 5.1110 13.4         # Utrecht Centraal
wanted 2 && shot 2_train_protection signals 52.3790 4.9000 16.6        # east of Amsterdam Centraal
wanted 3 && shot 3_speed speed 52.30 4.93 11.2                         # Amsterdam Zuidoost
wanted 4 && shot 4_electrification electrification 51.90 4.95 8.7      # HSL-Zuid and Betuweroute among 1.5 kV lines
wanted 5 && shot 5_operator operator 52.10 5.00 8.7
wanted 6 && shot 6_key signals 52.3790 4.9000 16.6 key
wanted 7 && shot 7_countries signals 52.3790 4.9000 16.6 packs

xcrun simctl terminate "$DEVICE" "$APP" 2>/dev/null || true
