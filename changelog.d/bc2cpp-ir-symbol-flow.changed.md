- **bc2cpp:** dispatch-table name sets for `send(*TABLE[i])` (yield_reach.rb) now come from the
  bytecode IR: `IrSymbolFlow` propagates Symbol values along `BytecodeIR.reaching_definitions` and
  replaces `SymbolFlow`'s own instruction walks. It also refuses tables the old walk accepted
  unsoundly (the table passed to or called on by a send, read as `X::TABLE`, an element written,
  the writer named as data, a `concat`-built entry, `send(:x, *TABLE[i])`), so optcarrot's
  `DISPATCH`, which `build_loop` reads with `DISPATCH.map`, is no longer proved. The universe is now
  the stored names only. Checked by `scripts/bc2cpp/symbol_flow_check.rb`, now in CI. See ADR 0499
  and `docs/bc2cpp-ir-symbol-flow.md`.
