- **The save/load file-select screen now draws its scroll indicator.**
  Confirmed against EasyRPG Player's source (`Scene_File`'s own
  `MakeArrowSprite`/`UpdateArrows`, not the generic list-window scroll
  mechanism, and not a scrollbar -- RPG_RT has no such thing): two
  independent blinking arrow sprites pinned at the top and bottom of the
  3-visible-of-15 slot viewport, shown only while a slot is hidden in that
  direction, reusing this engine's existing pause-arrow windowskin cells
  and 20-frame on/off blink timing.
