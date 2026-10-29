- The compiled load drops the `initialize` defs that no alias can copy: an `alias_method`
  of `initialize` in a class body copies only from that class's ancestors, so the stubbed
  bodies of unrelated classes (82 defs in the engine gems) leave the mrblib, and the boot
  set starts 89 fewer class bodies (1-frame New Game: 271 to 182 VM starts).
