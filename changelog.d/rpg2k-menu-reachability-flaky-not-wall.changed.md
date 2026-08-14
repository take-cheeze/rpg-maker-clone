- Documentation only: refines the previous note on the field-menu wine
  comparison's reachability issue. Further testing found the Equip screen
  *does* eventually open on genuine `RPG_RT.exe` -- a real reference frame
  deep in its weapon-slot item picker was captured -- so the earlier "never
  lands" description was too strong. The confirm key past the second cursor
  position is flaky rather than blocked: the same blind-retry recipe opened
  Equip in six tries on one run and failed after twenty on the next, and a
  pixel-diff early-exit made captures *less* reliable by firing on transient
  frames. `docs/TODO.md` now describes this as a race in the Xvfb/wine/
  xdotool input queue that needs a steadier environment or smarter
  automation to pin down, not a structural wall in the engine or the field
  menu itself.
