# dmgbuild settings for Orbite's disk image: the app, a link to Applications and an arrow between them.
# Used by scripts/release.sh: uvx dmgbuild -s scripts/dmg/settings.py -D app=<Orbite.app> "Orbite <version>" <out.dmg>
import os.path

application = defines.get("app", "build/release/Orbite.app")  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)

format = "ULFO"
filesystem = "APFS"
files = [application]
symlinks = {"Applications": "/Applications"}
badge_icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")

background = defines.get("background", "scripts/dmg/background.tiff")  # noqa: F821
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {appname: (180, 190), "Applications": (480, 190)}
