# UI credits

Panel art: **Pixel Holo UI** by Helianthus Games, https://helianthus-games.itch.io/pixel-holo-ui (paid itch.io pack, bought by the team).

Licence (full text in `assets/ui/pixel_holo_ui/License.txt`): non-exclusive right to use the assets in commercial and personal derivative works, attribution not required, assets may be modified. The raw asset files may NOT be redistributed or shared other than inside the game itself, so do not republish `assets/ui/pixel_holo_ui/` on its own (asset stores, templates, packs).

Used (all from `assets/ui/pixel_holo_ui/`, as nine-patches tinted by the theme, see `config/theme.luau`):
- `button_simple/Normal/button_normal.png` (slice 3/2/3/2): panels (`panelSkin`), tint `dim`.
- `button/Normal/button_normal.png` and `button/Hover/button_hover.png` (slice 5/6/5/6): nav, top bar, speed and form buttons (`buttonSkin`); the Hover art is the selected one.
- `scrollbar_horizontal/Normal` and `Clicked` (slice 3/3/3/3): gauge track and fill (`gaugeSkin`).

Not used: `panel/Clean/panel.png` (its 15 px sides carry decorative chromatic-aberration stripes that read as ghost borders on a stretched panel), the `Scanlines` variants, `title_panel*`, `panel_left/right`, dividers, vertical scrollbar, cursors, loading wheel, planet selector, icons. They stay in the repo for later screens.
