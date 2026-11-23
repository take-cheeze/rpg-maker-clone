- **bc2cpp**: the compiled gems share one owner-class slot table instead of
  one each, and the `[]`/`[]=` helpers are one copy for the program
  (Wio: -1.5 KB static RAM, -5.9 KB flash).
