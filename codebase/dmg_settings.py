# dmgbuild settings for KeyRemapper
import os

# dmgbuild exec()s this file, so __file__ is not defined. Use cwd instead
# (build_dmg.sh always runs dmgbuild from the project root).
_app_path = os.path.abspath(os.path.join(os.getcwd(), ".build", "KeyRemapper.app"))

# Volume name
volume_name = "KeyRemapper"

# Format
format = "UDZO"

# Compression level
compression_level = 9

# Volume icon (use the app's icon)
badge_icon = os.path.join(_app_path, "Contents", "Resources", "applet.icns")

# Background image
background = os.path.join(os.getcwd(), ".build", "dmg-background.png")

# Background tiling
background_tile = False

# Window size and position
window_rect = ((100, 100), (640, 340))

# Icon view options
icon_size = 96
text_size = 14

# Icon positions — centers, aligned with the arrow drawn in the
# background image (drawn ~170px from the top of the 340px window).
icon_locations = {
    "KeyRemapper.app": (150, 140),
    "Applications": (490, 140),
}

# Applications symlink
symlinks = {
    "Applications": "/Applications",
}

# Files to include
files = [_app_path]
