- **Message text:** A `\.` (quarter-second) or `\|` (full-second) pause can
  no longer be cut short by pressing Decision or Cancel -- matching RPG_RT's
  own `Window_Message::Update`, these are frame countdowns unaffected by
  input; only `\!` waits for a button. Test Play's own Shift fast-forward
  still speeds through them as before.
