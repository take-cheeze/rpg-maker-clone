- **bc2cpp** (ADR 0465): the whole-program fixed points (the class, ivar, Array-element and Hash-element layout sweeps
  and the return-class and numeric pool growth in `CodeGen.new`) run under a hard round limit. Reaching it while facts
  still change stops the build with an error naming the analysis and the loop; a layout sweep no longer silently keeps
  a table that was still changing after 10 rounds.
