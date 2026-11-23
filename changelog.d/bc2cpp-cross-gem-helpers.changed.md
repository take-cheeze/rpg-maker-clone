- **bc2cpp**: prelude helpers that several compiled gems print alike are kept
  once per image instead of once per gem (`CROSS_GEM_SHARE`,
  `BC2CPP_CROSS_GEM_SHARE=0` turns it off); the owner-call miss path is one
  body for every gem (`OWNER_CALL_CORE`, `BC2CPP_OWNER_CALL_CORE=0`), and the
  instance-type class list is one flat table (`BC2CPP_INSTANCE_TT_FLAT=0`).
  The Wio Terminal image is 24.7 KB smaller.
