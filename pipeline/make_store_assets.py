#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joel Haasnoot
"""Write the app store graphics in the fastlane layout that Google Play tooling and F-Droid read:
the 512 px icon and the 1024 x 500 feature graphic, drawn from the launcher icon's geometry in
make_app_icon.py, and captioned phone screenshots framed from take_screenshots.sh captures.

With --platform ios it frames the take_ios_screenshots.sh captures instead, into a fastlane deliver
screenshots folder: iPhone captures (ios/) at 1320 x 2868 for the 6.9" and 1284 x 2778 for the 6.5"
display slots, and iPad captures (ipad/) at 2064 x 2752 for the 13" iPad slot.

Text is set in Roboto, found in the Android SDK (platforms/android-28 ships it) or Android Studio;
pass --font-dir to use another folder holding Roboto-Medium.ttf and Roboto-Bold.ttf.

Usage: make_store_assets.py <raw screenshots dir> <fastlane images dir> [--font-dir DIR]
       make_store_assets.py --platform ios <raw screenshots dir, holding ios/ and ipad/> <fastlane screenshots/en-US dir>
"""
import argparse
import glob
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_app_icon import BAR, BOTTOM, CENTER, DARK, GLOW, GLOW_RADIUS, GREEN, ORANGE, TOP, UNLIT  # noqa: E402

SS = 4  # supersampling for smooth edges
WHITE = (255, 255, 255, 255)

# Caption per capture, in the order the store shows them.
CAPTIONS = {
    "1_infrastructure": "OpenRailwayMap, fully offline",
    "2_train_protection": "Signals and train protection, down to each signal",
    "3_speed": "Line speeds at a glance",
    "4_electrification": "Which lines are electrified, and at what voltage",
    "5_operator": "Operators and station codes",
    "6_key": "A key for every colour and symbol",
    "7_countries": "Download a country once, use it anywhere",
}


# App Store screenshot sets: file prefix, capture folder (under the raw screenshots dir) and size.
# App Store Connect has separate 6.9" and 6.5" iPhone slots; both are framed from the iPhone captures.
IOS_SETS = [
    ("iPhone69", "ios", (1320, 2868)),
    ("iPhone65", "ios", (1284, 2778)),
    ("iPadPro13", "ipad", (2064, 2752)),
]


def rgba(argb):
    """'#AARRGGBB' as used in the vector drawables to a Pillow RGBA tuple."""
    value = argb.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (2, 4, 6, 0))


def find_fonts(font_dir):
    dirs = [font_dir] if font_dir else []
    for sdk in (os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
                os.path.expanduser("~/Library/Android/sdk"), os.path.expanduser("~/Android/Sdk")):
        if sdk:
            dirs += sorted(glob.glob(os.path.join(sdk, "platforms", "*", "data", "fonts")))
    dirs += glob.glob("/Applications/Android Studio.app/Contents/plugins/design-tools/resources/layoutlib/data/fonts")
    dirs += glob.glob(os.path.expanduser(
        "~/Applications/Android Studio.app/Contents/plugins/design-tools/resources/layoutlib/data/fonts"))
    for d in dirs:
        medium, bold = os.path.join(d, "Roboto-Medium.ttf"), os.path.join(d, "Roboto-Bold.ttf")
        if os.path.exists(medium) and os.path.exists(bold):
            return medium, bold
    sys.exit("Roboto not found; pass --font-dir with Roboto-Medium.ttf and Roboto-Bold.ttf")


def draw_signal(size, unit):
    """The signal head on a transparent square of `size` px, `unit` px per head unit, centred."""
    s = size * SS
    u = unit * SS
    ox = s / 2 - CENTER[0] * u
    oy = s / 2 - CENTER[1] * u
    img = Image.new("RGBA", (s, s))
    draw = ImageDraw.Draw(img)
    x, y, w, h = BAR
    draw.rounded_rectangle((ox + x * u, oy + y * u, ox + (x + w) * u, oy + (y + h) * u), radius=w / 2 * u,
                           fill=rgba(DARK))

    def lamp(cx, cy, r, colour, target):
        ImageDraw.Draw(target).ellipse((ox + (cx - r) * u, oy + (cy - r) * u, ox + (cx + r) * u, oy + (cy + r) * u),
                                       fill=colour)

    lamp(*TOP, rgba(UNLIT), img)
    glow = Image.new("RGBA", (s, s))
    lamp(BOTTOM[0], BOTTOM[1], GLOW_RADIUS, rgba(GLOW), glow)
    img = Image.alpha_composite(img, glow)
    lamp(*BOTTOM, rgba(GREEN), img)
    return img.resize((size, size), Image.LANCZOS)


def make_icon(path):
    # Play masks the icon to a rounded square; the signal gets about two thirds of the height,
    # a little less than on the launcher, where the mask crops more.
    size = 512
    icon = Image.new("RGBA", (size, size), rgba(ORANGE))
    icon = Image.alpha_composite(icon, draw_signal(size, size / 16.55 * 0.66))
    # Play wants the icon as a 32-bit PNG (with alpha); the feature graphic and screenshots as 24-bit.
    icon.save(path, optimize=True)


def rounded_mask(size, radius):
    mask = Image.new("L", (size[0] * SS, size[1] * SS))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] * SS - 1, size[1] * SS - 1), radius=radius * SS, fill=255)
    return mask.resize(size, Image.LANCZOS)


def wrap(draw, text, font, max_width):
    """One line if it fits, otherwise two lines of about equal width (no lone word on the second)."""
    words = text.split()
    if draw.textlength(text, font=font) <= max_width:
        return [text]
    splits = [(" ".join(words[:i]), " ".join(words[i:])) for i in range(1, len(words))]
    return list(min(splits, key=lambda s: max(draw.textlength(s[0], font=font), draw.textlength(s[1], font=font))))


def make_feature_graphic(path, map_shot, fonts):
    width, height = 1024, 500
    img = Image.new("RGBA", (width, height), rgba(ORANGE))

    # A piece of the map on the right, below the view chips and above the buttons.
    shot = Image.open(map_shot).convert("RGBA")
    map_width = 540
    scale = map_width / shot.width
    crop = shot.crop((0, 300, shot.width, 300 + round(height / scale))).resize((map_width, height), Image.LANCZOS)
    mask = Image.new("L", (width * SS, height * SS))
    ImageDraw.Draw(mask).polygon([(620 * SS, 0), (width * SS, 0), (width * SS, height * SS), (500 * SS, height * SS)],
                                 fill=255)
    mask = mask.resize((width, height), Image.LANCZOS)
    layer = Image.new("RGBA", (width, height))
    layer.paste(crop, (width - map_width, 0))
    img.paste(layer, (0, 0), mask)

    signal = draw_signal(260, 13)
    img = Image.alpha_composite(img, _placed(signal, (width, height), (-10, 120)))

    draw = ImageDraw.Draw(img)
    title = ImageFont.truetype(fonts[1], 64)
    tagline = ImageFont.truetype(fonts[0], 28)
    draw.text((210, 150), "Offline", font=title, fill=WHITE)
    draw.text((210, 222), "Rail Map", font=title, fill=WHITE)
    draw.text((212, 312), "Railway maps without", font=tagline, fill=WHITE)
    draw.text((212, 348), "a connection", font=tagline, fill=WHITE)
    img.convert("RGB").save(path, optimize=True)


def _placed(layer, canvas_size, offset):
    canvas = Image.new("RGBA", canvas_size)
    canvas.paste(layer, offset, layer)
    return canvas


def make_screenshot(path, shot_path, caption, fonts, size=(1080, 1920)):
    """Frames a capture: caption on the app's orange above a dark-bezelled phone that runs off the
    bottom edge. The result has `size`: 1080 x 1920 for Play, 1320 x 2868 for the App Store. The layout
    is designed at 1080 wide and scaled to the width."""
    width, height = size
    k = width / 1080

    def px(value):
        return round(value * k)

    img = Image.new("RGBA", (width, height), rgba(ORANGE))

    shot = Image.open(shot_path).convert("RGBA")
    screen_width = px(840)
    screen = shot.resize((screen_width, round(shot.height * screen_width / shot.width)), Image.LANCZOS)
    bezel = px(18)
    phone_size = (screen.width + 2 * bezel, screen.height + 2 * bezel)
    phone_x, phone_y = (width - phone_size[0]) // 2, px(420)

    shadow = Image.new("RGBA", (width, height))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (phone_x, phone_y + px(16), phone_x + phone_size[0], phone_y + px(16) + phone_size[1]), radius=px(64),
        fill=(58, 22, 0, 110))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(px(24))))

    phone = Image.new("RGBA", phone_size, rgba(DARK))
    phone.paste(screen, (bezel, bezel), rounded_mask(screen.size, px(46)))
    img.paste(phone, (phone_x, phone_y), rounded_mask(phone_size, px(64)))

    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(fonts[1], px(72))
    lines = wrap(draw, caption, font, px(920))
    line_height = px(88)
    y = (phone_y - len(lines) * line_height) // 2 + px(6)
    for line in lines:
        draw.text((width / 2, y), line, font=font, fill=WHITE, anchor="ma")
        y += line_height
    img.convert("RGB").save(path, optimize=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("shots", help="folder with the captures from take_screenshots.sh")
    parser.add_argument("images", help="fastlane images folder, e.g. fastlane/metadata/android/en-US/images")
    parser.add_argument("--font-dir")
    parser.add_argument("--platform", choices=["android", "ios"], default="android")
    args = parser.parse_args()
    fonts = find_fonts(args.font_dir)

    if args.platform == "ios":
        # fastlane deliver picks the device from the image size, so all sets share one folder.
        os.makedirs(args.images, exist_ok=True)
        written = 0
        for prefix, captures, size in IOS_SETS:
            shots_dir = os.path.join(args.shots, captures)
            if not os.path.isdir(shots_dir):
                print(f"skipping {prefix}: no captures in {shots_dir}")
                continue
            for index, (name, caption) in enumerate(CAPTIONS.items()):
                shot = os.path.join(shots_dir, f"{name}.png")
                if not os.path.exists(shot):
                    sys.exit(f"missing capture {shot}; run take_ios_screenshots.sh first")
                make_screenshot(os.path.join(args.images, f"{prefix}-{index + 1}-{name.split('_', 1)[1]}.png"), shot,
                                caption, fonts, size=size)
                written += 1
        print(f"wrote {written} App Store screenshots to {args.images}")
        return

    phone_dir = os.path.join(args.images, "phoneScreenshots")
    os.makedirs(phone_dir, exist_ok=True)
    make_icon(os.path.join(args.images, "icon.png"))
    make_feature_graphic(os.path.join(args.images, "featureGraphic.png"),
                         os.path.join(args.shots, "1_infrastructure.png"), fonts)
    for name, caption in CAPTIONS.items():
        shot = os.path.join(args.shots, f"{name}.png")
        if not os.path.exists(shot):
            sys.exit(f"missing capture {shot}; run take_screenshots.sh first")
        make_screenshot(os.path.join(phone_dir, f"{name}.png"), shot, caption, fonts)
    print(f"wrote icon, feature graphic and {len(CAPTIONS)} phone screenshots to {args.images}")


if __name__ == "__main__":
    main()
