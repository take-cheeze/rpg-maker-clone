- **Events:** Message Options and Change Face Graphic now block and retry
  while a different message window is already open, matching RPG_RT --
  previously both applied immediately regardless, so a still-running
  Parallel Process could mutate the shared message window's
  transparency/position/face graphic mid-display over another event's
  open text.
