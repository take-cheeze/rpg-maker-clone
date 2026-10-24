# Native direct-call ABI

A **direct call** lets compiled Ruby call a native method's C body without going
through mruby's method dispatch. The compiler emits `rgss::NAME_direct(M, self,
args...)` instead of a by-name send, behind a guard that proves the receiver's
class. This page describes the calling convention those calls use, and the
conditions a body must meet. The decisions are in ADR 0253 (wio's hand split),
ADR 0257 (core entries), and ADR 0263 (the generated RGSS split).

## Two entry shapes

Every native method exists in two forms.

| Form | Signature | Used by |
|---|---|---|
| By-name binding | `mrb_value f(mrb_state* M, mrb_value self)` | mruby's method table |
| Direct entry | `mrb_value NAME_direct(mrb_state* M, mrb_value self, <typed args>)` | compiled call sites |

The binding is what `mrb_define_method` registers. It unpacks its arguments with
`mrb_get_args` (or `mrb_get_argc` and `mrb_get_arg1`) and then runs the body. The
direct entry takes the same arguments already unpacked and typed, with no
argument parsing. For a generated RGSS entry, the split looks like this:

```c
// the body moves into NAME_native_body, which reads no calling frame
mrb_value bmp_decoder_ran(mrb_state* M, mrb_value self) { ... }

// the direct entry forwards to it
mrb_value bmp_decoder_ran_direct(mrb_state* M, mrb_value self) {
  return bmp_decoder_ran(M, self);
}
```

The body text is moved, never copied, so the binding and the direct path run one
body. `include/rgss_native_direct.hxx` declares every direct entry, and the forwarders
are in a generated block at the end of `mruby-rgss/src/lib.cxx`.

## What each form costs

The body is extracted once, not copied. Both forms call the same
`NAME_native_body`, so the code size of the body does not change.

- **Body (`NAME_native_body`):** the method's own work. Its cost is the same in
  either form.
- **By-name binding:** the `mrb_func_t` mruby calls through its method table. It
  pays the normal dispatch cost (the method lookup and the `mrb_get_args` unpack),
  then calls the body.
- **Direct form (`NAME_direct`):** a one-line forwarder to the body, with the
  arguments already typed. It skips dispatch and the unpack. The forwarder is in the
  same translation unit as the body, so an optimising build can inline it, and the
  direct path then calls the body directly.
- **Call site:** a guard check (the receiver's class, and `mrb_integer_p` for
  `:int` arguments) in place of the dispatched send. A failed guard takes the
  normal send, so a wrong class or argument still gets the same behaviour.
- **Code size:** one small function per direct entry, plus its declaration in
  `include/rgss_native_direct.hxx`.

The saving has not been measured. A runtime benchmark would be needed to give a
figure for the dispatch saved against the cost of the guard.

## Argument kinds

Each direct entry's parameters have one of four kinds. The compiler converts the
Ruby value to the C type before the call:

| Kind | C parameter | Conversion at the call site | Guard |
|---|---|---|---|
| `:int` | `mrb_int` | `mrb_integer(v)` | `mrb_integer_p(v)` |
| `:float` | `mrb_float` | `mrb_as_float(M, v)` | none; the same conversion the `f` format of `mrb_get_args` uses |
| `:bool` | `bool` | `mrb_test(v)` | none (truthiness) |
| `:value` | `mrb_value` | passed as is | none |

A call whose argument fails its guard takes the generic send instead, so the
behaviour (including the error for a bad argument) is the one dispatch gives.
`tools/bc2cpp/native_direct.rb` loads the table kinds the compiler accepts,
`int float bool value`. A kind the compiler does not know keeps the entry out.

## The receiver guard

A direct call is emitted in a chain of exact-class arms. Only a receiver whose
class is exactly the owner reaches the arm, so a subclass or a singleton class
falls through to dispatch.

- RGSS: `bc2cpp_native_class == rgss::<wrapper class>()`, comparing the receiver's
  class with the wrapper class the binding was registered on.
- Core Array: `mrb_array_p(r) && mrb_obj_ptr(r)->c == M->array_class`. Core String is
  the same with `string_class`. Integer needs only `mrb_integer_p(r)`, since an
  Integer is an immediate.

The guard, not the arm's body, decides which class the call belongs to, so an entry
for one owner never runs on another.

## What a body must satisfy

A body may be admitted as a direct entry only if it is **frame-independent**: its
result depends on its arguments and receiver, not on the calling frame. The checks
below are enforced, not conventions.

- It reads no frame API: `mrb_get_args`, `mrb_get_argc`, `mrb_get_argv`,
  `mrb_get_arg1`, `mrb_block_given_p`, `mrb_yield*`, `mrb_get_mid`,
  `mrb_call_super`, `mrb_get_backtrace`, and any access to the frame fields of
  `mrb_state` (`c`, `ci`, `root_c`) or of `mrb_context`, `mrb_callinfo` and `REnv`.
- It calls no mruby API that takes an `mrb_state` unless that API is on the reviewed
  allowlist (`MRB_API_ALLOW` in `scripts/native/binding_facts.py`). An unknown API
  may read the frame, so the body is refused.
- It has no statement before the argument unpack that could raise in a different
  order from the binding, no `goto`, no `#if` inside the body, and no template
  specialization. The `binding_split.rb` refusal list is the full set.

A body that fails any rule keeps its by-name binding. Nothing is dropped silently:
the generator reports the refusal reasons.

## Configuration guards

A binding that exists only in some builds gets its direct entry under the same `#if`
as its callee. Builds without the callee get a stub:

```c
mrb_value bmp_init_copy_direct(mrb_state* M, mrb_value self, mrb_value) {
  return native_split_compiled_out(M, self);  // raises NotImplementedError
}
```

Each configuration must define every entry point, really or as a stub, exactly where
the guard predicts its callee is compiled (ADR 0263). A mismatch fails
`binding_split.rb check`.

## Core natives (ADR 0257)

mruby's own methods are registered from static ROM tables, `MRB_MT_ENTRY(fn, SYM,
ARGS)`. `tools/bc2cpp/native_core_direct.rb` holds a hand-audited entry per method:
an expression over public mruby APIs, the arity and argument guard, and the
body text it was written against. `audit` re-checks each entry against the sources
on every compile and drops any entry that no longer matches.

`tools/bc2cpp/native_core_candidates.rb` proposes candidates from the clang AST of
a core source. A candidate is an entry whose body passes the frame rules above,
checked through the unit's own functions and the reviewed allowlist.

`scripts/bc2cpp/native_core_direct_wire.rb` turns the candidates on Array, String
and Integer with no arguments into entries in
`tools/bc2cpp/native_core_direct_generated.rb`. Such an entry calls the mruby
function itself. Its body text is pinned in the entry, so the audit drops it if
the function changes. Only a function with external linkage is wired: a `static`
function is not exported, so a call from generated code fails to link. The
candidates producer reports linkage from the AST, and the wired check reads each
definition to confirm it. Candidates whose body has conditional compilation, and operator-named
methods, are not wired: their frame verdict or their registration name is not
checked by the audit. `scripts/bc2cpp/native_core_direct_wired_check.rb` fails if
any generated or hand-audited entry stops verifying, since the audit would
otherwise drop it silently. It audits the hand-audited entries against the full
native source set of the closed world, because some of them pin bodies in mruby
gems (`Array#compact` is `mruby-array-ext`'s).

A hand-audited entry whose mruby function is `static`, or reads its arguments
with `mrb_get_args`, calls a helper instead (`bc2cpp_ary_delete`,
`bc2cpp_ary_index`, ...). The helper replays the function's block-less body over
public macros and MRB_API functions, so it runs without a call frame. When the
argument format converts its argument (`"i"`, `"A"`), the entry's argument guard
admits only the values for which that conversion is the identity (a fixnum, an
Array), and every other argument keeps the send.

These are not hand-rewritten, because no exact frame-free version exists:
`Array#inspect` writes `mrb->c->ci->mid` and its recursion guard walks the call
stack, and methods that yield need a block frame. `String#replace`,
`Hash#replace` and `String#index` call large `static` helpers with no public
equivalent. The same holds for `String#__chars`, `#ord`, `#__codepoints`,
`Array#__uniq` and `Hash#__compact` (`utf8code`, `ary_uniq_bang` and the hash
table internals are `static`). `String#__lines` and `Range#__num_to_a` write
`ci->mid`, which a call without a frame of its own would write into its caller's.

The entries also apply inside compiled mruby core bodies. Those bodies compile
with the closed world withheld, but an entry's safety rests only on program-wide
facts (no project definition, prepend or unknown mixin on the owner, no outside
definer), so they ask the same world, as the `*rest` receiver arm does. A core
body's receiver proof is itself a runtime class test, so the call stays behind it.

When the flow proves a receiver is exactly a core class (FLOW_CORE_DIRECT), the
send calls the compiled core body or, for a C method, the audited entry. That
happens before any guard chain over project classes that define the same name:
an exact core receiver can take none of their arms.

## Where the generated artifacts come from

| Artifact | Generator |
|---|---|
| `include/rgss_native_direct.hxx`, the forwarder block in `lib.cxx`, `tools/bc2cpp/native_direct_table.rb`, `mruby-rgss/test/native_direct_probe.inc` | `scripts/native/binding_split.rb write` |
| `generated/bc2cpp/rgss_direct.rbs` | `scripts/bc2cpp/native_rgss_direct_sigs.rb` |
| `generated/bc2cpp/core_direct.rbs` | `scripts/bc2cpp/native_core_direct_sigs.rb` |

`binding_split.rb check` fails when the committed files differ from what the
generator would write, and runs in the bc2cpp checks. The generator needs libclang's
Python bindings, which `nix develop .#clang` provides, and the mruby headers from a
host build with the `mruby-gc-type-live-counts` patch applied.

## Not covered

- Bodies that read the frame or call an unreviewed mruby API keep their by-name binding.
- Variadic functions, block-taking methods and functions returning an unlisted kind
  have no direct entry.
- The callee's result is an `mrb_value`; typed result kinds are declared separately
  in `declarations.rbs` and do not change this ABI.
