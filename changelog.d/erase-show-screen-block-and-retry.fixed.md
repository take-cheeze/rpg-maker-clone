- **Events:** Erase Screen and Show Screen now block (not run) while a
  message window or choice list is open, retrying once it closes -- the
  same block-and-retry family Show/Move/Erase Picture, Transfer Player,
  Battle Processing/Enemy Encounter, Change EXP/Level, Key Input
  Processing and Message Options/Change Face Graphic already join --
  previously a still-running parallel process could cut the screen to
  black (or back) out from under an on-screen message window.
