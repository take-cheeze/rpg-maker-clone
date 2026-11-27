- **Wio:** bc2cpp now gives a compiled method's GC arena entries back when the
  method has a declared-return guard, and keeps giving a loop's entries back
  when the method also has an Array literal. On the 192 KB board, the first
  message window of New Game held 261 arena entries, about 8 KB of them
  garbage. It now holds 54.
