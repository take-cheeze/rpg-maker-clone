bc2cpp: a direct construct may fill an #initialize's optional positionals

The positional direct-construct arm required the call's argument count to EQUAL
`mandatory_arity`, so an #initialize with `= default` arguments could never be
devirtualized -- and `dispatch_targets.rb`'s own comment recorded that as a
property of the class ("Classes whose #initialize has `= default` arguments and
no keywords (Game::Vehicle, Game::Character, ...) are omitted: they could never
fire"). It can: the compiled `_impl` already takes `mand + opt` positional
registers plus a trailing `bc2cpp_given_opt`, and its own OP_ENTER jump table
substitutes the default for a position that was not supplied.

So the call site now passes its real arguments, pads the omitted optionals with
`mrb_nil_value()` placeholders the default branch overwrites, and passes
`n - mand` as `bc2cpp_given_opt` -- exactly the shape
`compile_keyword_direct_construct` already emits for the keyword case
(KEYWORD_CONSTRUCT_OPTIONAL_POSITIONAL_SUPPORT). `optional_arg_table` must
resolve, which is what proves the jump target the table is about to take exists.

The defaults stay where they are: inside `_impl`, which is mruby's own compiled
body, so a `= 0` or `= nil` default is mruby's value and not one bc2cpp
re-derived. Nothing is invented at the call site, which is why this is a gate
relaxation and not a new inference.

Measured on the hot-only wio closed world, full compilation, core mrblib in the
world, BC2CPP_NO_ONLY_OWNERS=1: POLY 2365 -> 2363, MONO 2025 -> 2027, generated
C++ 18,514,504 -> 18,517,947 bytes. That is a small yield, and the measurement
says why: of the 60 sites whose class is in DIRECT_CONSTRUCT_TARGETS, only TWO
classes were blocked on the arity test at all (RPG2k::Scene::Map and
RPG2k::Scene::ChipsetEditor, both `mand=2 opt=0` -- pure-mandatory by another
route), and no listed class has a real `mand < opt` #initialize to fire on.

The 168 `RPG2k::Window` sites stay dynamic, and that is now a LISTING gap rather
than a soundness one: `def initialize(x = 0, y = 0, width = 0, height = 0)` has
four literal defaults and an `_impl` that already fills them, so with
RPG2k::Window added to DIRECT_CONSTRUCT_TARGETS they would all devirtualize.
That is left as the next step so this commit carries only the capability.

scripts/bc2cpp_*_check.rb: 44 pass, 5 fail -- the same 5 that fail at the commit
this branch started from.
