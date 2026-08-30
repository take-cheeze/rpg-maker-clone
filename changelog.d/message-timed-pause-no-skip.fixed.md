- **Message text:** A `\.` (quarter-second) or `\|` (full-second) pause can
  no longer be cut short by pressing Decision or Cancel -- ported from a
  reference implementation's own message-pause handling, not independently
  confirmed against genuine RPG_RT under wine: these are frame countdowns
  unaffected by input; only `\!` waits for a button. Test Play's own Shift
  fast-forward still speeds through them as before.
