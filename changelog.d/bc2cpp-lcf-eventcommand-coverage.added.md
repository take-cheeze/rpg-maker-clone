- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers
  `LCF::EventCommand#initialize`/`#param` (one decoded RPG2000
  event-page/common-event/move-route command) in `mruby-lcf-compiled`,
  alongside `LCF::MoveCommand#initialize`. Neither needed any new opcode
  work.

  This round's own dedicated diligence pass (checking the real embedding
  diagnostic rather than trusting `LCF::EventCommand`'s own pre-existing
  `# bc2cpp:` type annotation alone) found an eighth severe, live,
  already-shipped bug: `drop_unsafe_embeddings` (the AOT compiler's own
  gate deciding which instance variables are safe to embed directly into
  a real `RData` struct instead of the ordinary dynamic `iv_tbl`) never
  checked whether some *other*, native `attr_reader`/`attr_writer`/
  `attr_accessor` for that exact same ivar name already exists on the
  class. A plain `attr_reader`'s real C implementation reads the ordinary
  `iv_tbl` directly and has no way to see a value this compiler's own
  codegen instead wrote into the embedded struct -- so the native
  accessor silently returned `nil` regardless of what `#initialize` did.
  Confirmed already live in four already-shipped classes:
  `Game::State#x`/`#y`/`#direction` (the hero's own position/facing),
  `Game::Map#id`/`#revision`, `Game::ChipSet#animation_type`/
  `#animation_speed`, and `Game::Switches#revision`. Fixed at the root in
  `drop_unsafe_embeddings`, which now also drops any individual ivar name
  that collides with a same-owner, same-name native accessor -- this can
  only ever remove an embedding that was never safe, never turn a sound
  one unsound. All four affected classes' own real, registered entry
  points are completely unaffected; only their ivar access path
  underneath changed back to the ordinary, always-correct dynamic
  `iv_tbl`. See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own
  follow-up for the full writeup.
