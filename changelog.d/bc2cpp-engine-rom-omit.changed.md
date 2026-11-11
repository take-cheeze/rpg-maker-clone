- **bc2cpp**: the closed build leaves the engine's ROM method-table entries that nothing looks up out of the tables at
  compile time, as it does for mruby's own. The RGSS and LCF tables name their class (`MRB_MT_CLASS`), and the proof
  lists the entries to drop. The closed host table goes from 995 to 821 entries, with no run-time removal.
