- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 4 of
  `Game::Weather`'s own 5 real bytecode methods (the current
  screen-weather effect state), added to `mruby-rpg2k-compiled` alongside
  this round's other new target, `Game::Rng`. Neither needed any new
  opcode work.

  This round's own dedicated bug-hunt pass (a third in a row to find a
  real live bug) found and fixed a fifth severe, live, already-shipped
  bug in the whole-program MONO/POLY devirtualization registry: a real
  `def self.foo` compiles to a distinct `SDEF` opcode, never the ordinary
  `TDEF` this registry's own bytecode walk switched on, so a singleton
  method was completely invisible to it -- the same "invisible to the
  registry" shape the `attr_reader`/`Struct.new` fixes already closed,
  just for a third, distinct installation mechanism. Confirmed live:
  `Game.clamp` (`def self.clamp`) collided with `RPG2k::Scene::MapViewer
  #clamp`, the only bytecode-visible `:clamp` before this fix -- every one
  of dozens of already-compiled `Game.clamp(...)` call sites devirtualized
  straight into the wrong class's compiled body, harmless today only by
  luck (neither `#clamp` body reads `self`). A related, unluckier
  collision was also found and would have caused a guaranteed infinite
  recursion had `Game::Interpreter` (whose own `#trans_to_opacity` is
  literally `Game.trans_to_opacity(top_trans)`) ever joined a compiled
  gem's owner list. Fixed by registering each `SDEF` as a synthetic
  registry entry, so a same-named real instance method correctly flips
  MONO to POLY. Verified against the real generated code before and
  after. See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own
  follow-up.
