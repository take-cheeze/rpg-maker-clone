- **Character, face and menu graphics are now colour-keyed**, so their palette
  entry 0 is transparent instead of being blitted as an opaque block. CharSet
  graphics (the party leader's and every map event's), FaceSet portraits and the
  windowskin loaded by `Scene::Base` all loaded without the flag that the
  chipset, the title screen and the map's own windowskin already used. Found by
  the wine comparison: on Nepheshel's town map our renderer drew a solid pink
  rectangle over a wall where the genuine `RPG_RT.exe` drew nothing, because
  `CharSet/door.png`'s palette entry 0 is `#FF678B`. With the key applied the
  town frame is **pixel-identical** to RPG_RT (0 of 307200 pixels differ).
