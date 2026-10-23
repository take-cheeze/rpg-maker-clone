- bc2cpp's closed world is becoming the sealed RPG2000/2003 desktop host, built
  natively from the desktop gem set with the RPG2000/2003 format only, instead
  of maix's cross build. Work in progress: the closed-world build does not pass
  yet, because the desktop host's `--script` loader runs arbitrary Ruby.
- `3rd/effekseer` is ignored for dirty working-tree changes (`ignore = dirty` in
  `.gitmodules`), so its local line-ending noise no longer blocks commits.
