- bc2cpp answers reaching-definition questions in one place: `IrepScans`
  (`Irep#walk_writers`, `#constant_path`, `#preceding_run`) replaces the
  hand-written backward register walks in the registry, dispatch, layout,
  keyword-send, return-analysis, fixnum-proof and integer-constant passes, with
  each pass's skip/barrier/MOVE rules spelled as options. The generated C++ is
  byte-identical.
