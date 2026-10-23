- **bc2cpp** escape report (`BC2CPP_ESCAPE_REPORT`) gains an `ivars` row per confined `new` site: whether every ivar
  store that can reach the object is provably immediate (`tools/bc2cpp/escape_immediate_ivars.rb`). Report only; no
  generated code changes, and stack placement stays off. Design and the tripwire plan are in
  `docs/bc2cpp-immediate-ivars.md`, covered by `scripts/bc2cpp/immediate_ivars_check.rb`.
