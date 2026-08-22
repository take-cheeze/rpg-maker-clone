- **Map:** the on-screen Timer widget now matches RPG_RT's actual (odd but
  real) overflow behavior once a Timer Set pushes it past 99 minutes --
  previously it read a windowskin offset past the end of the digit strip and
  drew whatever pixels happened to be there instead of RPG_RT's own
  duplicated-colon, dropped-ones-digits pattern.
