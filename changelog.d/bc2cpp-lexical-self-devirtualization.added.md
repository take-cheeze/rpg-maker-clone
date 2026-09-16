- `tools/bc2cpp/bc2cpp.rb` can now devirtualize an implicit-self
  (`SSEND`/`SSEND0`) call to a genuinely POLY (multiply-defined) method
  name with NO runtime check at all -- stronger than every existing
  devirtualization path here (MONO excepted, which needs none either, but
  only ever fires when the flat name is unique program-wide). `self`
  inside a method body is not merely traced the way an explicit receiver
  register is (`trace_new_target`'s own runtime-guarded TYPED path,
  gated `!self_implicit` precisely because it has no register to
  backward-scan for an implicit receiver) -- it is *known outright*
  whenever the enclosing owner has no subclass anywhere in the whole
  program (an override further down the ancestor chain could otherwise
  answer differently) and self-rebinding never occurs in this closed
  world (`instance_eval`/`instance_exec`-style rebinding -- confirmed by
  grepping the actual mrblib source across all three gems: zero call
  sites). Both facts were already established and reused, not invented
  for this: `self_receiver_class` (this file's own return-class-inference
  pass) already answers exactly this question for value tracing; the new
  `lexical_self_owner` is its `compile_send`-side twin, reading the same
  reasoning off this `CodeGen` instance's own already-memoized
  `known_owner_set`/`subclassed_set` instead of a separately-built `ctx`
  hash.

  Two real codegen shapes land, both a strict `#error`-avoidance widening
  of two paths that already existed for an EXPLICIT receiver:

  - `LEXICAL_SELF`: the implicit-self analogue of MONO/TYPED for a
    compiled-body candidate -- `r2 = Owner_method_impl(M, self);`, no
    `if`, no `mrb_funcall` fallback.
  - `LEXICAL_SELF_IVAR_ACCESSOR`: the implicit-self analogue of
    IVAR_ACCESSOR_DEVIRT for an `attr_reader`/`attr_writer`/
    `attr_accessor` candidate -- a bare `mrb_iv_get`/`mrb_iv_set` against
    `self`, same "no runtime check" reasoning.

  Both reuse the exact same compile-clean/pure-mandatory-or-optional-
  arity/call-site-arity guards the existing MONO/TYPED/IVAR_ACCESSOR
  paths already apply to their own candidates -- nothing new invented on
  that front, just resolved through `owner_def.owner` (the enclosing
  method's own real owner, already threaded through every `compile_send`
  call site) instead of a traced receiver register. A `.singleton` owner
  (`def self.foo`'s own `self` is a Class/Module object, not an
  instance) is refused for the identical reason `self_receiver_class`
  itself refuses one.

  Verified against the real whole-program diagnostic, measured against
  this round's own immediate predecessor (the just-committed
  `POLY_SMALL_N` round, PR #1733): total `mrb_funcall`/
  `mrb_funcall_with_block` call sites drops **12757 → 12280**, 477 real
  call sites eliminated OUTRIGHT (zero fallback line remaining at all,
  unlike `POLY_SMALL_N`'s own one-fallback-per-site shape). `POLY-marked`
  drops 5176 → 4946, `everything else` drops 7581 → 7334, distinct
  dynamically-dispatched method names drops 1084 → 1033. Directly
  inspected real generated output for the real
  `mruby-rpg2k-compiled` gem: 472 real `LEXICAL_SELF` sites and 16 real
  `LEXICAL_SELF_IVAR_ACCESSOR` sites emitted (e.g. `Game::Battle::
  Combatant#dead?`/`#member?` called via implicit self inside sibling
  methods of the same class, `RPG2k::Scene::ChipsetEditor#refresh`,
  `Game::Actor#hp`/`#max_hp` -- each spot-checked against the real
  `game.rb` source: `Game::Actor` has zero subclasses anywhere in the
  program, `attr_accessor :hp, :mp`/`attr_reader :max_hp, ...` are real
  `Game::Actor`-owned accessors). `scripts/rpg2k_logic_check.rb` (1201
  checks), `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged.
