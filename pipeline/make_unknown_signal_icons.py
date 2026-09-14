#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Generate the "unknown signal" icons the app uses instead of upstream's question-mark pentagon.

OpenRailwayMap draws a signal whose type is not tagged (railway=signal only) with
general/signal-unknown, and a signal of a known type but unknown system with
general/signal-unknown-<type>, coloured by type. This writes replacements with the same
size (18 x 17.12, which the import uses to stack signals on a post) and the same type colours.

Usage: make_unknown_signal_icons.py <design> <upstream symbols/general dir> <output dir>
"""
import os
import re
import sys

W, H = 18, 17.119019
HEAD = "#262626"
NEUTRAL = "rgb(34.901961%, 34.901961%, 34.901961%)"

# Upstream question mark glyph (from signal-unknown.svg), centred at (8.96, 9.55), 9.1 tall.
QUESTION_MARK = (
    "M 7.8125 10.558594 C 7.8125 10.152344 7.898438 9.804688 8.070312 9.527344 C 8.242188 9.246094 "
    "8.539062 8.957031 8.957031 8.652344 C 9.324219 8.390625 9.589844 8.164062 9.742188 7.976562 C 9.910156 "
    "7.777344 9.992188 7.550781 9.992188 7.285156 C 9.992188 7.023438 9.890625 6.824219 9.695312 6.695312 C "
    "9.503906 6.554688 9.242188 6.484375 8.894531 6.484375 C 8.550781 6.484375 8.210938 6.539062 7.875 "
    "6.644531 C 7.535156 6.753906 7.195312 6.894531 6.835938 7.074219 L 6.1875 5.761719 C 6.585938 5.539062 "
    "7.023438 5.355469 7.492188 5.214844 C 7.957031 5.078125 8.472656 5.007812 9.03125 5.007812 C 9.882812 "
    "5.007812 10.546875 5.210938 11.011719 5.625 C 11.488281 6.035156 11.730469 6.554688 11.730469 7.1875 C "
    "11.730469 7.523438 11.671875 7.816406 11.566406 8.0625 C 11.460938 8.308594 11.296875 8.539062 11.085938 "
    "8.75 C 10.871094 8.957031 10.609375 9.179688 10.289062 9.417969 C 10.050781 9.589844 9.867188 9.738281 "
    "9.734375 9.859375 C 9.601562 9.984375 9.507812 10.101562 9.460938 10.21875 C 9.421875 10.332031 "
    "9.398438 10.476562 9.398438 10.648438 L 9.398438 11.003906 L 7.8125 11.003906 Z M 7.617188 13.0625 C "
    "7.617188 12.683594 7.71875 12.417969 7.921875 12.273438 C 8.128906 12.117188 8.378906 12.035156 8.675781 "
    "12.035156 C 8.960938 12.035156 9.207031 12.117188 9.414062 12.273438 C 9.621094 12.417969 9.71875 "
    "12.683594 9.71875 13.0625 C 9.71875 13.421875 9.621094 13.683594 9.414062 13.847656 C 9.207031 14.003906 "
    "8.960938 14.085938 8.675781 14.085938 C 8.378906 14.085938 8.128906 14.003906 7.921875 13.847656 C "
    "7.71875 13.683594 7.617188 13.421875 7.617188 13.0625 Z"
)


def question_mark(cx, cy, height, colour):
    s = height / 9.08
    return (f'<path fill="{colour}" transform="translate({cx} {cy}) scale({s:.4f}) translate(-8.96 -9.55)" '
            f'd="{QUESTION_MARK}"/>')


def design_head(accent):
    """A plain two-lamp signal head with unlit lamps, outlined in the type colour."""
    return (f'<rect x="5" y="0.55" width="8" height="16" rx="4" fill="{HEAD}" stroke="{accent}" stroke-width="1.1"/>'
            f'<circle cx="9" cy="4.6" r="2.25" fill="#b3b3b3"/>'
            f'<circle cx="9" cy="12.5" r="2.25" fill="#b3b3b3"/>')


def design_head_badge(accent):
    """A signal head with unlit lamps and a small question-mark badge in the type colour."""
    return (f'<rect x="1.6" y="0.55" width="7.8" height="16" rx="3.9" fill="{HEAD}"/>'
            f'<circle cx="5.5" cy="4.5" r="2.15" fill="#a6a6a6"/>'
            f'<circle cx="5.5" cy="12.4" r="2.15" fill="#a6a6a6"/>'
            f'<circle cx="12.9" cy="11.9" r="4.55" fill="#ffffff" stroke="{accent}" stroke-width="1.3"/>'
            + question_mark(12.9, 11.95, 5.4, accent))


def design_lamp(accent):
    """A single unlit lamp in a ring of the type colour."""
    return (f'<circle cx="9" cy="8.56" r="7.35" fill="#ffffff" stroke="{accent}" stroke-width="1.8"/>'
            f'<circle cx="9" cy="8.56" r="3.6" fill="{HEAD}"/>')


DESIGNS = {"head": design_head, "head-badge": design_head_badge, "lamp": design_lamp}


def svg(body):
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">{body}</svg>\n')


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in DESIGNS:
        sys.exit(f"usage: make_unknown_signal_icons.py <{'|'.join(DESIGNS)}> <upstream symbols/general> <out dir>")
    design, upstream, out = DESIGNS[sys.argv[1]], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)
    count = 0
    for name in sorted(os.listdir(upstream)):
        if not (name == "signal-unknown.svg" or re.fullmatch(r"signal-unknown-[a-z_]+\.svg", name)):
            continue
        source = open(os.path.join(upstream, name), encoding="utf-8").read()
        match = re.search(r'stroke="(rgb\([^)]*\))"', source)
        accent = match.group(1) if match else NEUTRAL
        with open(os.path.join(out, name), "w", encoding="utf-8") as f:
            f.write(svg(design(accent)))
        count += 1
    print(f"wrote {count} icons ({sys.argv[1]}) to {out}")


if __name__ == "__main__":
    main()
