- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers
  `LCF::Tree#initialize` (one decoded map-tree section: the
  currently-selected map id plus the flat list of every map id in tree
  order) in `mruby-lcf-compiled`, alongside `LCF::MoveCommand#initialize`/
  `LCF::EventCommand#initialize`/`#param`. No new opcode work was needed.

  Checked directly against the real embedding diagnostic, not assumed:
  neither `@selected_id` nor `@maps` gets embedded into a real `RData`
  struct today, since neither traces to a literal or an annotated
  argument (`LCF::Tree#initialize` carries no `# bc2cpp:` type
  annotation, unlike `LCF::EventCommand`). A temporary, experimental
  annotation (reverted before this change) confirmed a second, deliberate
  finding: even if `@selected_id` were made provably Fixnum, this class's
  own `attr_reader :selected_id, :maps` would collide with an embedded
  `@selected_id` the exact same way `LCF::EventCommand`'s `attr_reader
  :code, :indent` did (the eighth severe bug, a prior round), and the
  fix already shipped for that bug (`drop_unsafe_embeddings` refusing to
  embed any ivar with a same-owner, same-name native accessor) correctly
  suppresses it here too.
