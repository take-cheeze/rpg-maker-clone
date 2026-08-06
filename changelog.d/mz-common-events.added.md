- **MZ runs common events, and both kinds are checked.** `--mz_common_event_test`
  (`MZ_MODE=common`) turns on the switch a parallel common event is gated on and
  calls another common event by id, then reports each separately. They are
  different machinery: a parallel common event is not a map event — it exists
  only while its switch is on and `Game_CommonEvent` gives it an interpreter of
  its own — while Call Common Event builds a *child* interpreter nested inside
  the calling one, the only nesting the interpreter does. Neither had ever run,
  because the test bed's `CommonEvents.json` was empty; it now authors one of
  each. The state line also reports how many `Game_CommonEvent` objects the map
  holds and how many are active, which separates "the parallel event never
  started" from "it ran and its write went nowhere".
