# dmgbuild settings for the NotesVim disk image (see scripts/make-dmg.sh).
# dmgbuild writes the Finder window layout itself, so no Finder scripting is needed.
import os

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]  # noqa: F821
icon_locations = {name: (160, 175), "Applications": (440, 175)}

window_rect = ((200, 120), (600, 380))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
format = "ULFO"
filesystem = "HFS+"
hide_extension = [name]
