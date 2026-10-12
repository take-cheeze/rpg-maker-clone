- **bc2cpp** has an opt-in strict hint tier, `BC2CPP_STRICT_HINTS=1` (default off, the default
  output is byte-identical): the else arm of a guarded class-hint site (`TYPED`, `ELEMENT`,
  `IVAR_ACCESSOR`, `MONO_EMBED_GUARD`, `POLY_SMALL_N`, `POLY_TABLE`, interface tables) is
  `bc2cpp_hint_violation` instead of a by-name send. A wrong hint logs
  `[RPG2k] hint violation: <Class>#<name> at <Owner#method (FAMILY)>` and raises
  `BC2cppHintViolation` (a `NoMethodError`); `-DBC2CPP_NOMETHOD_VERIFY` aborts naming the site.
  Every forced site is marked, listed on stderr (`STRICT_HINT_SITE`) and gated by
  `tools/bc2cpp/strict_hints_reviewed.rb`. See `docs/adr/0411-bc2cpp-strict-hints.md` and
  `docs/bc2cpp-strict-hints.md`; covered by `scripts/bc2cpp/strict_hints_check.rb`, its mutation
  check and `strict_hints_reviewed_check.rb` (nightly `strict-hints` shard).
