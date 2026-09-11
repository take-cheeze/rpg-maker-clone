- Extended the opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler
  (`tools/bc2cpp/bc2cpp.rb`) to cover `Game::Interpreter`
  (`mruby-rpg2k/mrblib/interpreter.rb`, plus a 4-method reopening in
  `mruby-rpg2k/mrblib/game/battle_support.rb`) for the first time --
  already registry-visible for MONO/POLY devirtualization soundness, but
  never before an emission owner in any compiled gem. By far the
  largest class this project's `bc2cpp` covers: 173 of its own 207 real
  bytecode-defined methods compile clean and are registered in
  `mruby-rpg2k-compiled/src/register.cxx`; the other 34 stay on the
  interpreter for real, individually confirmed gaps (a real Ruby block,
  a `rescue` clause, a still-unmodeled `JMPUW` opcode, a keyword-heavy
  call, or a non-mandatory `#initialize`-style argument -- never a
  silent drop). No ivar of this class ends up embedded.
- Found and fixed a real, previously-undiscovered gap in `bc2cpp.rb`'s
  own `drop_unsafe_embeddings` ivar-embedding safety gate while chasing
  down exactly that "no ivar embeds" result for `Game::Interpreter`'s
  own `@frame_steps`: the gate only ever checked that a class's own
  `#initialize` compiles clean, never that *every other* method
  touching a candidate ivar (nested Ruby block bodies included) also
  compiles. A method that stays on the interpreter for any of this
  compiler's already-established reasons still runs its own ordinary
  `SETIV`/`GETIV` bytecode against the object's real, separate dynamic
  `iv_tbl` (`struct RData` carries one independently of the embedded
  struct's own `data` pointer) -- silently diverging from every
  *compiled* sibling method's own struct-field access to the same ivar
  name. Confirmed this was already live, not hypothetical, in
  already-shipped code: `Game::Transition`'s own `@width`/`@height`
  were real embedded struct fields, but 6 of its own real methods
  (`#block_rects`/`#blind_rects`/`#vertical_stripe_rects`/
  `#horizontal_stripe_rects`/`#clip`/`#compute_block_order`, all
  genuine Ruby-block users) also read one or both while staying
  uncompiled -- a real, live crash (`nil` where a real ivar value
  belonged) in every merged build enabling this gem, not a missed
  optimization. Fixed by a new `every_accessor_compiles?` check,
  recursing into nested block child ireps to find every real touch
  site; re-verified all three compiled gems' generated output
  byte-identical before/after except for `Game::Transition` losing
  `@width`/`@height`'s embedding (and its now-unneeded
  `MRB_SET_INSTANCE_TT` call) -- every registered method's own
  arity/visibility is completely unaffected. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up for the
  full writeup.
