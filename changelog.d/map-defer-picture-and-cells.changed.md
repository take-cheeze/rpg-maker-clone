- **RPG2000 map, less heap**: the picture layer and the hero's, vehicles' and
  airship shadow's sprite bitmaps record their draws (`Bitmap#_defer`) instead
  of holding pixels, so a shown picture no longer keeps a 300 KB screen-sized
  buffer and a map no longer keeps four 3 KB character cells.
