# 0148: bc2cpp optional positional-argument support

## Status

Accepted.

## Context

Every non-mandatory argument shape (`optional`/`rest`/`mandatory2`/`keyword`/
`kwrest`/`block`, the six non-first fields of `ENTER`'s own real aspec) has
been unconditionally unsupported since bc2cpp's first version -- any method
using any of them fell straight to `#error ... has non-mandatory arguments
... -- not in this prototype's supported subset`. A real closed-world
survey of every currently-uncompiled such method (grouping each by exactly
which `ENTER` fields are nonzero) found 160 real methods blocked this way,
overwhelmingly dominated by one single shape: 115 (72%) are blocked by
plain positional optional arguments alone (`def foo(a, b = 1)`), nothing
else nonzero -- including a large number of `#initialize` methods
(`Game::Troop`, `Game::Party`, `Game::Enemy`, `Game::Character`,
`Game::Vehicle`, `Game::Weather`, `Game::MoveCommand`, `RPG2k::Window`,
`RGSS::Font`, `RGSS::Window`, `Game::TextReveal`, `Game::Battle`, ...). The
next largest shape, real keyword arguments, accounts for 29 methods; every
other shape (rest args, a block parameter, or a combination) is in the
single digits. Scoped this round to the dominant shape alone, matching this
file's own established "start from the one real, zero/near-zero-risk shape,
not everything nonzero at once" pattern (e.g. ADR 0147's `#times`-only
scope for BLOCK/SENDB) -- keyword arguments, real `*rest`/`**kwrest`, and a
block parameter all stay unconditionally unmodeled, exactly as before this
round.

Real ENTER-then-jump-table shape, confirmed directly against real
disassembly rather than assumed from `vm.c`'s own `OP_ENTER` comment alone:
`def foo(a, b = 1, c = 2)` compiles to `ENTER 1:2:0:0:0:0:0:0` followed
immediately by exactly `optional + 1` real, addressable `JMP` instructions
-- entry *k* (0-indexed, *k* = how many of the real optional arguments THIS
call actually supplied) jumps straight to wherever the bytecode starts
computing the `(k+1)`th optional argument's own default-value expression,
falling straight through to the next optional's own computation, or
straight to the method's own real first statement once every supplied
default is filled in. This *is* the real mruby VM's own `OP_ENTER` PC-skip
mechanism (`3rd/mruby/src/vm.c`), just replayed here as an ordinary native
`switch`/`goto` instead of relying on any VM PC arithmetic -- confirmed
against three real default-value shapes directly (a literal, a reference to
an *earlier* optional argument's own already-computed value, and an ivar
read), not just the literal case.

## Decision

`optional_arg_table` recognizes the one real shape above (`ENTER`'s
`optional` field nonzero, every other non-mandatory field zero, and the
real jump table matching exactly `optional + 1` consecutive `JMP`
instructions right after `ENTER`) and returns the jump table's own real
target addresses; `compile_method` uses the same suppressed-address/
glue-at mechanism RESCUE_SUPPORT/BLOCK_SUPPORT already established to
replace those `optional + 1` `JMP` instructions with one native
`emit_optional_dispatch` switch on a new, real `bc2cpp_given_opt`
parameter -- everything else in the region (each optional's own
default-value computation, already ordinary, already-supported bytecode)
is completely untouched, reached only by `goto` from this switch exactly
the way the real VM's own PC-skip reaches it. This means every default-
value expression this file can already translate just works, unmodified,
regardless of shape -- no new opcode had to be added for this round at
all, only the calling convention around already-supported ones.

Calling convention: a method with `opt` real optional arguments gets
`mand + opt` real `mrb_value` parameters (mandatory ones keep whatever
NATIVE_ARG_TARGETS type they already had; every optional position is
always plain `mrb_value`, since that set only ever names already-pure-
mandatory methods) plus one extra `mrb_int bc2cpp_given_opt` parameter.
A caller that doesn't supply an optional argument still passes a real
(harmless, `mrb_nil_value()`) placeholder for its own slot -- it is never
read before the jump table's own default-value code overwrites the
matching register, the same trust model this file's own embedded-ivar
codegen already uses elsewhere (a real, defined placeholder, never
uninitialized reads). The ordinary entry wrapper (the plain `mrb_func_t`
every `mrb_define_method` call actually registers) computes the real
`bc2cpp_given_opt` from `mrb_get_argc(M) - mand`, clamped to `[0, opt]` --
the exact same quantity the real VM's own `OP_ENTER` computes -- and
extracts the real argument values via `mrb_get_args` with mruby's own
`|` optional-argument marker landing exactly at the mandatory/optional
boundary.

Devirtualization (compile_send's MONO/TYPED direct-call and
DIRECT_CONSTRUCT_TARGETS' `.new` shortcuts) is deliberately left
completely untouched this round: every one of those paths still gates on
`pure_mandatory_arity?`, so an optional-arg method is simply never chosen
as a direct-call target -- every real call to one goes through the
ordinary entry wrapper above (interpreted dispatch, `#send`, or a POLY-name
`mrb_funcall`), which is unconditionally correct and needs no further
change. Ivar embedding (`drop_unsafe_embeddings`) is left untouched for the
same reason: it also still gates on `pure_mandatory_arity?(init)`, so an
optional-arg `#initialize` still never gets its own ivars embedded into a
real struct field this round (confirmed directly: a real `def
initialize(x = 5); @x = x; end` compiles clean under this round's own new
support, but `@x` still uses ordinary `mrb_iv_set`, and the class still
does not appear in the real `== classes needing MRB_SET_INSTANCE_TT ==`
diagnostic). Extending either of those to also cover this round's own new
optional-arg calling convention is real, valid future work, deliberately
left out to keep this round scoped to the compiler capability alone --
matching this file's own established practice of shipping the opcode/
calling-convention capability in one PR (verified end-to-end, but without
touching any `*-compiled` gem's own hand-maintained owners list/
`register.cxx`) and a separate later "coverage round" PR wiring specific
newly-unlocked methods into a shipped gem (see ADR 0147's own identical
split, confirmed against its own PR history: `.times` inlining shipped
alone, the 16 methods it unlocked were wired into `register.cxx` by none
of that same PR's own commits).

## Verification

- Real runtime test against a freshly-built vanilla mruby core: a 1
  mandatory + 1 optional method called with 1 and 2 real arguments; a
  method whose two optional defaults reference an earlier argument and an
  ivar respectively (`def combo(a, b = a + 1, c = @x)`), called with 1, 2,
  and 3 real arguments; an all-optional 3-argument method
  (`def triple(a = 1, b = 2, c = 3)`) called with 0 through 3 real
  arguments, exercising every entry of its own real jump table; the same
  method reached through `#send` (the exact same entry wrapper interpreted
  dispatch uses); and a call supplying MORE positional arguments than
  `mandatory + optional`, confirmed to raise a real `ArgumentError` (mruby's
  own `mrb_get_args`, not any new code here) rather than silently
  misbehaving. All pass.
- Real end-to-end regen of all three `*-compiled` gems (`ONLY_OWNERS`/
  `OTHER_OWNERS`/`NATIVE_SRCS`/`OTHER_DECLS_HEADER` computed exactly the
  way each gem's own `mrbgem.rake` does, a real two-pass run since
  `OTHER_DECLS_HEADER` for gem A needs gem B's own already-produced
  `_decls.h`): zero regressions -- every method that compiled clean before
  this round still compiles to byte-for-byte identical output, and the
  whole-program MONO/POLY registry diff is empty. 67 previously-`#error`
  real methods within these three gems' own already-covered owners now
  compile clean (56 in `mruby-rpg2k-compiled`, 11 in `mruby-rgss-compiled`,
  zero in `mruby-lcf-compiled` -- no optional-arg method exists in its own
  currently-covered owners), the remaining 48 of the whole closed-world
  survey's 115 living in classes no gem covers yet (a separate, later
  coverage-round decision). None of the 67 are wired into any
  `register.cxx` this round (see Decision). With `SKIP_UNSUPPORTED=1` (the
  real build's own flag), all three gems' own `register.cxx` compile
  clean against the regenerated output with a real g++, `-fsyntax-only`.
- Confirmed directly, not assumed: an optional-arg `#initialize` still
  never triggers ivar embedding or `MRB_SET_INSTANCE_TT`, and a call site
  passing too many positional arguments to a newly-compiled optional-arg
  method still raises `ArgumentError` rather than reading past its own real
  parameter list.
- Found and fixed one real, previously-latent bug during this same
  verification pass, caught by a real g++ compile rather than shipped: a
  Ruby local variable/argument name is an ordinary identifier in Ruby's own
  grammar but can still collide with a C++ reserved word --
  `RPG2k::Scene::Map#page_field(name, default)` has a real, literal
  `default` parameter (mruby-rpg2k/mrblib/scene/map.rb) that
  `arg_names`-based codegen previously emitted completely unescaped
  (`mrb_value default` as a real parameter/local declaration). Pre-existing
  (present before this round too, confirmed against a real before/after),
  not something this round introduced -- this round's own end-to-end
  `register.cxx` compile pass is what surfaced it, since `page_field`
  still doesn't compile clean today either way (a separate, unrelated
  `rescue`+`yield` gap). Fixed with a new `sanitize_c_ident` helper
  (a small, real-collision-only `CPP_RESERVED_WORDS` set, not a full C++
  keyword table) that every `arg_names` entry now passes through.

## Consequences

- Keyword arguments (29 real methods), `*rest`/`**kwrest` (7 + kwrest
  cases), and a block parameter (5) stay unconditionally `#error` --
  keyword arguments in particular need at least two new opcodes (`KEY_P`/
  `KARG`, plus `KEYEND` when no `**kwrest` is declared), confirmed directly
  against real disassembly, and are real, valid follow-up work.
- Devirtualization and ivar embedding both still treat every optional-arg
  method exactly as unsupported (dynamic dispatch only, never embedded) --
  extending either to this round's own new calling convention is valid
  future work, not attempted here.
- Wiring any of the 115 newly-unlocked methods into a shipped gem's own
  `register.cxx` (choosing `MRB_ARGS_ARG(mand, opt)` per method, updating
  each owner's own registration-block comment) is a separate, later
  "coverage round" PR, not this one -- see Decision.
