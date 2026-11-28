- **RPG2k maps**: an event whose current page never moves, animates or runs on
  its own is kept as a 16-byte record instead of a full event object, and is
  expanded only when something touches it, checks it or names it; big maps
  need far less heap on the Wio Terminal.
