- **bc2cpp**: element reads in a rescue's try body, a block that stays a function and an inlined loop body are
  rooted only where the value is held across a call or leaves the body still held, as in a method's own body
  (`BC2CPP_ELEMENT_READ_BODIES=0` roots every one). On the Wio closed world this drops 200 of 4669 roots: internal
  flash −48 B, QSPI image −1352 B.
