- **bc2cpp:** `CLOSED_WORLD_CONSTANT_OBJECT` no longer calls a singleton method
  directly when an `alias`/`undef`/`define_method` names it (for example
  `alias read other` inside `class << Const`) or when the closed world is refused
  for a dynamic installer or mixin; the site keeps its by-name dispatch.
