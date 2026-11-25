- **bc2cpp: smaller `rescue` bodies.** A compiled method's protected range
  keeps only the locals its handler or later code reads tied to the method's
  frame, and its arithmetic slow paths share the cold helpers the rest of the
  compiled code uses: about 5 KB less Wio flash. `BC2CPP_RESCUE_LIVE_REFS=0`
  and `BC2CPP_RESCUE_TRY_COLD=0` turn the two parts off.
