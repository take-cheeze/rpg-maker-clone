- A **Control Variables** operand the runtime does not implement no longer
  writes a junk value. The fallthrough returned `param5`, which is the operand's
  own *selector* rather than any value — so RPG2003's battle operand (now
  implemented) stored the troop member index in the target variable, and a
  Maniac-patch operand would store an actor id or a switch number. Unknown
  operands now read 0 and log which operand was asked for.
