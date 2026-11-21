- The closed bc2cpp build declares the element class of the battle's
  combatant lists and of the message reveal's pause and speed marker lists.
  Block iterators over them check each element on entry and call its
  methods directly, which removes 4 owner calls (1258 -> 1254). The base
  section also drops 60 orphan header lines left by the old
  `base_section_check --write`.
