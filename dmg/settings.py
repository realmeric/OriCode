# dmgbuild's settings for OriCode.dmg's window, which scripts/dmg.sh passes it. Positions are
# points, y from the top, matching render.swift's Layout.
#
#   dmgbuild -s dmg/settings.py -D app=/path/to/OriCode.app -D dir=dmg OriCode OriCode.dmg

import os.path

app = defines.get("app", "OriCode.app")  # noqa: F821
here = defines.get("dir", ".")  # noqa: F821, the folder with background.tiff

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: it sets FinderInfo on the bundle, which codesign --strict refuses, and
# Finder hides .app without it unless "Show all filename extensions" is on.

background = os.path.join(here, "background.tiff")
# Finder counts its 32pt title bar in the height, so the art's 400 needs 432.
window_rect = ((200, 120), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (160, 184),
    "Applications": (480, 184),
}
arrange_by = None
label_pos = "bottom"
