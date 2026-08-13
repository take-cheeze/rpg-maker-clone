- **RPG2000/2003**: the field menu's **End Game** command now calls
  `return_to_title` immediately, the same as F12 and the "Return to Title
  Screen" event command, instead of first showing a "Returning to title..."
  message and waiting on a second button press to dismiss it before tearing
  the scene stack down. The extra confirmation step was pure added latency
  measured with `RGSS::Profiler`: the teardown/rebuild itself costs the same
  ~5ms whether triggered from the bare map or with the field menu open on
  top, so the wait was not buying any safety, just an extra round-trip.
