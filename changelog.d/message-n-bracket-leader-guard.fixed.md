- **Message text:** A bare `\N[]`, or `\N[x]` where `x` is neither a digit
  nor a `\V[]`/`\v[]` reference, now expands to nothing -- matching RPG_RT's
  own `Game_Message::ParseParam`, the party-leader substitution for actor id
  0 only applies when a digit or a resolvable nested `\V[]` was actually
  read inside the brackets. Previously any unparseable `\N[]` bracket named
  the party leader instead.
