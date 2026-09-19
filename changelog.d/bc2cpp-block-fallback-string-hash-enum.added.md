- **bc2cpp** admits 12 more synchronous block receivers to
  `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` — `gsub gsub! sub sub! scan` (String),
  `each_value` (Hash), `with_index` (Enumerator), `step` (Numeric) and `zip`
  (Enumerable/Enumerator) — so a block that captures an enclosing-method upvar
  and is handed to one of them compiles through the same cfunc-backed-RProc
  fallback `each`/`map`/`flat_map` already use, instead of an honest
  `#error unhandled opcode BLOCK`/`SENDB`. Each entry was vetted against the
  list's own safety rule (yield synchronously, never store the block) and the
  `Lazy#zip`/`Lazy#with_index` twins are unreachable because `mruby-enum-lazy`
  is not built. The optcarrot scoping probe goes 96.3%→99.2% (369→380 methods;
  the whole `BLOCK`/`SENDB` `#error` bucket drops to zero, BLOCK_FALLBACK
  regions 49→72); `scripts/bc2cpp_coverage_report.rb`'s real-project output is
  byte-identical with and without the change.
