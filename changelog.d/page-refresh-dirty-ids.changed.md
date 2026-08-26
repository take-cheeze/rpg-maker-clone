- **Event page refreshes are keyed to the switches/variables a page actually
  reads.** The map scene re-selected every event's page whenever *any*
  switch, variable, party or timer revision moved — so a parallel process
  ticking one unrelated counter every frame dragged the whole map through
  page re-selection every frame (~5ms on a 21-event town, more on larger
  maps, measured on the Android test device). Switches and Variables now
  record *which* ids were written since the last sweep, the scene keeps a
  per-event index of the ids its pages' conditions reference, and the sweep
  re-selects only the events whose referenced inputs moved; party and timer
  movement still re-select everything they can affect. Behavior is
  unchanged — the same conditions are tested, just on fewer frames — and
  the full page-flip check suite (929 scene + 1137 logic checks) passes.
