- Documentation only: `docs/TODO.md` now records that the Skill screen's
  empty-list fix (from the previous change) is wine-confirmed against genuine
  `RPG_RT.exe`, not just inferred from the identical Item-screen code path,
  and documents a reachability wall hit while extending the same wine
  comparison to the Equip and Save screens -- confirming the menu cursor
  moves correctly under Xvfb/wine but the follow-up confirm key reliably
  fails to register two or more cursor positions in, across every timing,
  window-targeting and key-choice variant tried. Left as a note for whoever
  picks up that comparison next, rather than a guessed-at engine fix.
