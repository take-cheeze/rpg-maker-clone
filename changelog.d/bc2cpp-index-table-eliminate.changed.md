- Eliminate `[]` / `[]=` from the closed build's method tables. The
  INDEX_CLOSED planner verdict (ADR 0365, tools/bc2cpp/index_closed_planner.rb)
  now also drives the static dispatch proof: planner-proven operators are
  admitted to the unregistered lists, run in both fixpoints, and leave out
  core ROM entries. 16 engine entries, 7 core ROM entries and 2 class-side
  entries go; the proof still converges in two passes.
