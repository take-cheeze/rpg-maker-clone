- **LCF map writer:** `.lmu` (map) files written by this codebase's LCF
  serializer now carry the trailing root terminator byte a genuine `.lmu`
  requires — previously it was always omitted (correct for `.lsd`/`.ldb`,
  but not `.lmu`), and a genuine RPG_RT.exe hangs on a black screen trying
  to load a map file written without it.
