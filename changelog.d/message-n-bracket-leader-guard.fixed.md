- **Message text:** A bare `\N[]`, or `\N[x]` where `x` is neither a digit
  nor a `\V[]`/`\v[]` reference, now expands to nothing -- ported from a
  reference implementation's own `\N[]` parsing, not independently
  confirmed against genuine RPG_RT under wine: the party-leader substitution
  for actor id 0 only applies when a digit or a resolvable nested `\V[]` was
  actually read inside the brackets. Previously any unparseable `\N[]` bracket named
  the party leader instead.
