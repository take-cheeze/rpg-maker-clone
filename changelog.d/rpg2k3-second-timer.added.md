- **RPG2003's second countdown timer.** The Timer Operation command's sixth
  parameter selects which timer it acts on — RPG2000 data never carries it, so it
  reads 0 and addresses the only timer that edition has. The new timer is read
  back by **Control Variables** (operand 7, selector 9) and by **Conditional
  Branch** type 10, which is laid out exactly like the existing timer test, and
  is drawn in its own window to the right of the first. The start operation's
  second flag — **keep running in battle** — is honoured as well: without it a
  timer pauses *and* hides for the duration of a fight rather than being stopped.
  The countdown itself moves into a `Game::Timer` value object; both timers
  persist in the save, and a save written before the second one existed still
  loads.
