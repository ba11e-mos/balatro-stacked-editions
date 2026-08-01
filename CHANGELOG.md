# Changelog

## 1.0.0

Initial release.

- Editions apply additively instead of replacing each other; effects, costs and
  Negative slots stack.
- Every edition's shader is blended onto the card so all of them stay visible.
- Info box badges show a count for duplicated editions (`2X Polychrome`).
- The Wheel of Fortune, Ectoplasm, Hex and Aura accept targets that already have
  an edition.
- Compatibility shim for mods that pick edition targets with `not card.edition`;
  Black Seal is handled out of the box, and
  `StackedEditions.with_editions_hidden(fn, skip_key)` is exposed for others.
- Config: allow duplicates, blend overlays, max editions per card.
