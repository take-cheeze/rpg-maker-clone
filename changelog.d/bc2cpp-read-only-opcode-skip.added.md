- **bc2cpp**'s `IvarLayout.trace_type` no longer mistakes eight genuinely
  read-only opcodes (`RETURN`, `RETURN_BLK`, `BREAK`, `JMPIF`, `JMPNOT`,
  `JMPNIL`, `RAISEIF`, `MATCHERR`) for an unrecognized register write during
  its backward ivar-type trace -- a real, sound precision fix (verified with
  a standalone repro), though it does not yet embed anything new in the real
  project: the one live case it types (`RPG2k::Window#@pause`) is still
  blocked by that class's own separate, already-documented optional-argument
  `#initialize` gap. See ADR 0188.
- **`RPG2k::Window`** is now in `BC2CPP_WIRED_EMBEDDINGS`, so bc2cpp's own
  generated registration installs all 35 of its compiled entry points
  (verified: `scripts/bc2cpp_wired_embedding_check.rb` reports 35/35) --
  closing a real drift in the hand-written `register.cxx` where `#dispose`
  compiled clean but was never installed and kept running interpreted. No
  ivar of `RPG2k::Window` embeds as a result (confirmed against the
  regenerated code: zero new struct fields).
