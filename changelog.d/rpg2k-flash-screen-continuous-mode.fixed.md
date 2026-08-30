- **RPG2003's Flash Screen command now supports its Begin/End continuous-strobe
  mode**, instead of always running the RPG2000 one-shot fade. Ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine: a 7th command parameter, present only on
  RPG2003 command lists, dispatches between a one-shot flash, an indefinitely
  repeating strobe that re-arms to peak strength every time it would settle,
  and an explicit stop. This build never read that parameter, so every
  Begin/End flash silently ran as a single fade-and-stop.
