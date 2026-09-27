bc2cpp: resolve a relative constant receiver of `.new` (RELATIVE_CONST_UNDER_NEW)

`trace_new_target`'s GETCONST arm refused under `resolving_new` and fell through
to the written path, so a `.new` receiver written as a RELATIVE constant named
no class at all. Inside `module LCF`, `EventCommand.new` is `GETCONST
EventCommand`, not `GETMCNST LCF` + `GETMCNST EventCommand`, so the shape that
the walk could not read is also the common one.

Every other opcode in that walk refuses under `resolving_new` for a real
reason: during a `.new` chain the register holds the CLASS EXPRESSION, not the
object, so `Klass.new` must not read `@x = SOME_INT_CONST` as an Integer
receiver, nor `[1,2].map` as an Array receiver. A constant is different in kind
-- it is a class NAME, not a value -- so resolving it is the point of the walk.
The safety test is that the name must BE a class the closed world defines,
checked against `known_owners` (the registry's own owner Set, the same input
`resolve_owner_name` and `UniqueClassNames.resolve` already use). A non-class
constant such as POS_BOTTOM is not in that set, so it still resolves to nothing
and its behaviour is unchanged.

Ambiguity is refused exactly as `lexically_resolve_construct_target` refuses
it: the caller's own lexical nesting is walked innermost-first and the name
resolves only when exactly ONE level matches. So this can turn a nil into a
class, never into the wrong one, and a bare name that could fall through to a
same-named top-level constant still resolves to nothing.

Measured on the hot-only wio closed world, full compilation, core mrblib in the
world, BC2CPP_NO_ONLY_OWNERS=1: 5019 relative-constant receivers reach the new
arm, of which 732 resolve to 18 distinct real classes -- 17 of them wired
embeddings (Game::Interpreter::BattleRequest, Game::Message::Segment,
Game::Message::PauseMarker, RPG2k::Scene::Map::MapEventState, ...). The 4287
refusals are correct rather than a gap: they are cross-gem classes not owned by
this run's registry (Game::State -> LCF::Array1D, RPG2k::Scene::Map -> Bitmap),
and naming a class this gem did not compile would be a guess.

Output-neutral for now -- nothing consumes the extra resolution yet, so POLY
(2242), TYPED (615) and object `.text` (3,940,130) are all unchanged. It is
landed because the resolver was previously answering nil for a shape it can
answer, and because the obvious consumer (per-owner `#initialize` argument
inference) is blocked on a different, cross-gem owner set rather than on this.

Verified: generated C++ compiles clean, object .text 3,940,130 byte-identical,
and scripts/bc2cpp_*_check.rb is 46 pass / 5 fail -- the same 5 that fail at the
commit this branch started from.
