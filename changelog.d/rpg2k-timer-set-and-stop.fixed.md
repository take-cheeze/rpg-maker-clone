- Two RPG_RT timer details, corrected by porting from a reference
  implementation's timer handling, not independently confirmed against
  genuine RPG_RT under wine. **Set** seeds `seconds * 60 + 59`, not
  `seconds * 60`: the display shows
  `frames / 60`, so a timer seeded exactly dropped a second after a single frame
  instead of holding the number it was given for a whole second. And **stopping
  a timer hides it** — `StopTimer` clears the visible flag as well as the running
  one, and the countdown reaching zero goes through that same stop, which is how
  a finished timer leaves the screen rather than sitting at `0:00`. This runtime
  had taken the opposite reading (a stopped timer stayed on screen, frozen).
