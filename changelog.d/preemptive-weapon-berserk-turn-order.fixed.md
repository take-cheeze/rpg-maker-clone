- **Battle:** a `preemptive` (先制攻撃) weapon's turn-order jump to the front
  of the round no longer drops when its wielder is forced to attack under
  Berserk -- matching RPG_RT's own `CreateExecutionOrder`, whose `+9999`
  bonus keys purely on a `Type::Normal` attack plus the weapon flag, with no
  dependency on whether that attack was forced by Berserk or Confusion.
  Previously a berserked wielder lost the jump and fell back to plain
  agility ordering.
