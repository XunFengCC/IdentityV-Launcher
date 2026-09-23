import os

application = os.path.abspath(defines["app"])  # noqa: F821
background_pdf = os.path.abspath(defines["background"])  # noqa: F821
app_name = os.path.basename(application)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [application]
symlinks = {"Applications": "/Applications"}

# Finder stores an alias to this vector PDF directly in .DS_Store.
background = background_pdf
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((160, 180), (660, 360))
default_view = "icon-view"
show_icon_preview = True
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 112
# These centres align with the vector arrow in the 660 × 360 PDF.
icon_locations = {
    app_name: (165, 145),
    "Applications": (495, 145),
}
