# App icon

- `ReadbackCheck_icon.svg`: the icon, a disk with the copy coming back to it.
  It is drawn for 64 px and up.
- `ReadbackCheck_icon_small.svg`: the same drawing simplified for 16 and 32 px.
  At those sizes the thin arc over the disk looks like a padlock, so this
  version has no slot, a thicker arc and tip, and a bigger LED.
- `AppIcon.appiconset`: the PNGs. `icon_16x16`, `icon_16x16@2x` and
  `icon_32x32` come from the small drawing; the rest come from the full one.
- `AppIcon.icns`: what both build scripts copy into the bundle.

To rebuild the .icns after changing a PNG:

```bash
mkdir -p /tmp/AppIcon.iconset && cp AppIcon.appiconset/*.png /tmp/AppIcon.iconset/ && iconutil -c icns /tmp/AppIcon.iconset -o AppIcon.icns
```
