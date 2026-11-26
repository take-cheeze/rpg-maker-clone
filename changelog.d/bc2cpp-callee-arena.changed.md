- **bc2cpp**: a compiled method called directly, and a compiled loop at each
  iteration, now give their GC arena entries back as the interpreter does, so a
  map load no longer keeps every object it made rooted until the frame ends
  (Wio map-load peak: map355 arena ~181 KB to ~22 KB, map371/map120/battle
  load peaks 120–150 KB lower). `BC2CPP_CALLEE_ARENA=0` and
  `BC2CPP_LOOP_ARENA=0` turn the two parts off.
