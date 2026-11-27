- **New Game and Continue release the title screen before building the map.**
  The title picture, command window and their bitmaps are disposed before the
  map loads, rather than after the map scene is built, so they are no longer
  held during the map build, which is the 192 KB Wio's peak. If the build fails,
  the error is logged as before and the title is rebuilt, fully open. Windows
  now dispose their own layer bitmaps too.
