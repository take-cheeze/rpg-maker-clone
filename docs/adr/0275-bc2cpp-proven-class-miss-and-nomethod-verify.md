# 275. A send to a proven class that nothing answers is a build error; verify mode for dead sites

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0226 makes a proven-dead guard-chain fallback a build error unless
reviewed. It only covers sends that reach a guard chain. Two other outcomes
stay silent:

- a dynamic send (`mrb_funcall`) whose receiver class the compiler knows, but
  whose class chain has no definition of the name. It compiles cleanly and
  raises `NoMethodError` in play. The coverage report counts these as
  `dynamic_no_registered_definition` and `traced_class_no_direct_target`, but
  most of them are guarded hints (a ClassLayout ivar hint, an annotation, an
  element hint), which may simply be wrong or too narrow. They are not proofs.
- an unguarded MONO call (the name has one definition anywhere) on a receiver
  proven to be an unrelated class. It calls the other class's body instead of
  raising.

Separately, `bc2cpp_nomethod` dispatches before raising (ADR 0262), so if a
dead-code proof is wrong and a method exists, the site raises "proof violated"
as an ordinary Ruby exception. A `rescue` in the game can hide that.

## Decision

### Proven-class miss is a build error unless reviewed

`ClosedWorld#proven_miss?` answers "a send of `name` to a receiver of proven
class K can only raise NoMethodError". It only ever adds a build error, so
every question defaults to "not a miss":

- a global refusal, an installer-made or unknown definer of the name, a name
  spelled in any outside native or Ruby source, or an outside `def` found by a
  broad scan (see below) is never a miss;
- the name must be defined by no class in K's chain: K, its ancestors and its
  descendants are not among the definers or their descendants
  (`required_classes`), and every definer is a declared, non-opaque class;
- a name passed to `respond_to?`, `method_defined?`, `instance_method`, `method` and
  similar (`PROBE_SENDS`) anywhere in the closed world is guarded, not a miss;
- `method_missing` in K's chain makes it not a miss;
- a site inside an irep with a `rescue`, or nested in a block under one, is not a
  miss (`CodeGen#rescue_covered_labels`), since the rescue may catch the
  `NoMethodError`.

The receiver proofs are unguarded facts only (`CodeGen#proven_receiver_class`):

| kind | proof |
| --- | --- |
| `fresh_new` | the dominating writer is a literal `Klass.new` (`exact_new_receiver_class`) |
| `literal` | the dominating writer is an Array, Hash or String literal (never for an implicit-self send, whose receiver register still holds an old value) |
| `lexical_self` | `self` in a method of a declared class (`closed_world_site`), no `instance_eval`/`instance_exec` rebinding anywhere |
| `constant_object` | a stable class or module constant (`constant_object_owner`) |

ClassLayout hints, argument and element annotations, and return-class facts are
guarded and never make a site of this kind. Return-class proofs
(`ret_class_proof`) are not used either; they feed the trace as hints.

Sites are marked `/* CLOSED_WORLD proven_miss: <kind> <Class>.<name> */` in the
POLY tail and in the unguarded MONO branch. `tools/bc2cpp/bc2cpp.rb` lists them
(`== closed world proven-class miss sites ==`) and aborts on an unreviewed one,
or on a listed one that a method this run compiled no longer has, exactly as
ADR 0226 does (skipped for the stale half on a hot-only run).
`tools/bc2cpp/proven_miss_reviewed.rb` holds `PROVEN_MISS_REVIEWED`, with keys
`"<owner>#<method> -> <name> (<kind> <Class>)"`. A separate list keeps each
entry a read-and-judged decision, not a bulk regeneration of ADR 0226's
3,000+ keys.
`scripts/bc2cpp_proven_miss_update.rb [--write]` regenerates it;
`scripts/bc2cpp_proven_miss_check.rb` (CI `bc2cpp-checks`, hot-only shard) has
fixtures for every case above and re-proves the list over the wio run of all
gems. `BC2CPP_NOMETHOD_UNREVIEWED=allow` (fixtures only) also turns this abort
into a warning.

### Outside `def` behind a modifier

`foreign_method_names` only sees a `def` at the start of a line, so
`private def loop` (mruby's `Kernel#loop`) was not an outside definition. A
first version of the proven-miss analysis reported `loop` in the engine as a miss
because of it. `ClosedWorld` now also keeps `@outside_def_names`, a broad
`def <name>` scan of the outside Ruby, and `proven_miss?` refuses those names.
The existing ADR 0210/0226 analysis still uses `foreign_method_names` and is
unchanged; it may have the same blind spot (see Consequences).

### `BC2CPP_NOMETHOD_VERIFY`

Defining the C++ macro `BC2CPP_NOMETHOD_VERIFY` when compiling generated code
changes `bc2cpp_nomethod_argv` to print `bc2cpp: NOMETHOD_VERIFY: dead site
reached: Class#name (N arg(s))` and `abort()` before dispatching, so a wrong proof
cannot run a method or be swallowed by a `rescue`. `build_config.rb` defines the
macro for the C++ compiler only when the environment variable
`BC2CPP_NOMETHOD_VERIFY=1` is set during the build. Without the macro the helper
is ADR 0262's unchanged (dispatch first, then `NoMethodError` or the
"proof violated" `RuntimeError`), and the macro does not exist in any shipped
build. `docs/bc2cpp-nomethod-verify.md` says how to run the smoke suites with it.
`scripts/bc2cpp_nomethod_verify_check.rb` (`bc2cpp-checks`, fast shard) builds the
emitted helper against a real mruby core both ways: normal mode dispatches and
raises, verify mode aborts with the site named and the method never runs.

## Consequences

- At introduction the whole wio world (4 compiled gems) has no proven-class miss:
  the list is empty. Several hundred dynamic-send sites with a proven
  receiver were all defined, native, or guarded; of the 279 hint-only receivers
  in the same run, none would be a miss even if the hint were true. The
  `dynamic_no_registered_definition` count in the coverage report is therefore
  core or native names, not missing methods.
- A new typo on a fresh object, a literal, `self` or a class constant now stops
  the closed-world build. The check costs one more listing per gem run (no extra
  compile).
- Not covered: receivers proven only by return-class facts, block parameters and
  ivars (hints), and any class with a mixin in its chain (a module definer is
  opaque). They keep dispatch.
- The verify build only does anything where the hot list compiles a
  `bc2cpp_nomethod` site. The shipped hot list has none today (ADR 0226), so a
  useful run needs `BC2CPP_HOT_ONLY=0` too; that is documented, not automated.
- Follow-up: `foreign_method_names` misses `private def name`, so ADR 0210's proof for
  such a name (mruby core has `loop`) is weaker than it looks. Widening it changes
  which fallbacks convert and so NOMETHOD_REVIEWED, so it is left for its own change.
