bc2cpp: list RPG2k::Window for direct construct, and keep a keyworded
#initialize on the keyword path

Listing RPG2k::Window is what the two previous commits were for. With
LEXICAL_CONSTRUCT_RESOLUTION a bare `Window.new` inside `class RPG2k` resolves to
RPG2k::Window (and not to RGSS::Window, which UniqueClassNames refuses outright
because the bare name has two bindings program-wide), and with
POSITIONAL_OPTIONAL_CONSTRUCT its `def initialize(x = 0, y = 0, width = 0, height
= 0)` no longer blocks a direct call: the `_impl` already fills those defaults
from its own OP_ENTER jump table given `bc2cpp_given_opt`.

Its four gates were checked live before listing: no `self.new`/`self.allocate`
anywhere in the closed world, an #initialize that compiles clean, a call count
inside [0, 4], and RPG2k::Window is in ONLY_OWNERS and is a wired embedding. 56
of its sites devirtualize, all passing 4 real arguments with bc2cpp_given_opt=4,
verified against the generated C++.

**This also fixes a build break the previous commit (0486b7e2) introduced.**
Relaxing the positional arm's arity test let it handle a class whose #initialize
also declares KEYWORDS -- RPG2k::Scene::Map and RPG2k::Scene::ChipsetEditor,
both `def initialize(parent, state, apply_access: true)`. Their `_impl` is
widened to take the keywords as trailing (value, given) pairs, so the positional
call was a too-few-argument compile error:

  error: too few arguments to function 'mrb_value
  RPG2k__Scene__Map_initialize_impl(mrb_state*, mrb_value, mrb_value, mrb_value,
  mrb_value, mrb_int)'

A class with keywords belongs to compile_keyword_direct_construct, which matches
keywords BY NAME and pads positionals itself, so the positional arm now refuses
it explicitly. Where the arity had lined up, the same bug would have silently
dropped the keyword values rather than failing to compile.

That break was missed because 0486b7e2 was verified with the check suite only,
which does not compile the generated C++. Verified this time by compiling the
generated unit: the full hot-only wio closed world with core mrblib and
BC2CPP_NO_ONLY_OWNERS=1 builds clean (object .text 3,935,247).

Measured on that build: POLY 2363 -> 2309, MONO 2027 -> 2081, direct-construct
`:new` sites 371 -> 425 across 23 classes. The object is 22,587 bytes larger
than before the optional-construct and Window work -- the expected direction, since
a guarded direct call is bigger than the one mrb_funcall it replaces, and this is
a CPU trade rather than a flash one.

scripts/bc2cpp_*_check.rb: 44 pass, 5 fail -- the same 5 that fail at the commit
this branch started from.
