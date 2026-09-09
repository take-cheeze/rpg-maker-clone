- **Wio Terminal (and PSP): stripped the dead sixel/iTerm2 image encoders.**
  `mruby-rgss/src/sixel.cxx` and `src/iterm.cxx` were compiled unconditionally,
  but their only caller (`sixel_display_create`/`iterm_display_create`) is
  `src/main.cxx`'s desktop-only `--sixel`/`--iterm` flags -- neither wio nor
  PSP can select a terminal backend at all (`terminal.cxx` already excludes
  its own implementation there for the same reason). Gated both files behind
  the identical `!PSP_BUILD && !WIO_TERMINAL` condition `terminal.cxx` uses.
  `iterm.cxx` was the bigger one: it pulls in `stb_image_write`'s bundled
  DEFLATE/PNG encoder, a real compressor nothing else in this build needs
  (the game-asset loader only ever inflates).
  Real ARM cross-compile: sixel.cxx 2,219 -> 12 bytes, iterm.cxx
  16,408 -> 12 bytes of `.text` (18,603 bytes combined). See ADR 127.
