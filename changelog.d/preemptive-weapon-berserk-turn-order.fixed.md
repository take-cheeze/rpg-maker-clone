- **Battle:** a `preemptive` (先制攻撃) weapon's turn-order jump to the front
  of the round drops when its wielder is forced to attack under Berserk,
  confirmed against a genuine RPG_RT.exe under wine: a berserked, agi-1
  wielder of a preemptive weapon went *second*, not first, against a single
  agi-250 enemy. A prior revision of this fragment claimed the opposite
  (that the jump does *not* drop under Berserk, "matching RPG_RT's own
  `CreateExecutionOrder`") based on reading a reference implementation's
  source as treating Berserk and Confusion identically; that reading was
  not itself checked against genuine RPG_RT, and this cycle's wine capture
  contradicts it for Berserk specifically. Confusion is untouched by this
  fix and still earns the jump, unconfirmed either way for genuine RPG_RT.
