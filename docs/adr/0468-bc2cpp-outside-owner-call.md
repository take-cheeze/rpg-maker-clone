# 0468. bc2cpp: name owner sets, leaf-class construction and constructor overloads

Date: 2026-10-16

## Status

Accepted

## Context

bc2cpp is a closed-world compiler (ADR 0466). Its guard chains call a compiled Ruby body for each class that can
answer a name, and ADR 0210 ends a complete chain in a NoMethodError raise. A chain keeps a by-name `bc2cpp_send`
as its else for one reason more than any other: the name is also defined outside the closed world's Ruby, by
mruby's C core, a gem's C/C++ source, or mrblib Ruby. `ClosedWorld#refusal` answered that with
`CLOSED_WORLD kept: core_or_native` for the whole name. Only two narrow lifts existed: the RGSS arms of ADR 0253
(frame-independent RGSS entry points, `mruby-rgss/src` only) and the per-class proof of ADR 0323 (a proven receiver
set that never reaches a native).

The wio shipped pass on master (`4f240167`) has 135 such sites. By name: `name` 28, `delete` 21, `string` 12, `at`
10, `name=` 8, `resume` 8, `include?` 7, `count` 5, `write` 8, `print` 5, `alive?` 3, `digits` 3, `result` 2,
`member?` 2, `members` 2, `index` 2, `flash` 2, `step` 2, `flush`, `shift`, `set`, `start` and `color` 1 each. The
Ruby targets of the chains are `Game::Troop#name` and its siblings, `LCF::File#delete`, `LCF::EventCommand#string`,
`Game::Message::PauseMarker#at`, `RPG2k::Scene::Menu#resume`, `RGSS::ErrorReport::Tee#write`/`#print`/`#flush`,
`ShopQuantity#count`, `NumberInput#digits` and the rest.

Better receiver typing (RBS, ivar layouts, nil narrowing) would close only a few of these. The receivers are array
elements, block parameters and call results (`actor.name` over a party, `cmd.string` over an event list), whose
class the existing facts do not bound. What the analysis lacked was not the receiver. It lacked the owners: it knew
that a native spells `delete`, but did not use which classes the native and mrblib definitions land on.

## Decision

### Name every outside owner

For a name `n`, the owners are:

* each native registration of `n`, by the class it lands on. This is `NativeOwnerMap` (ADR 0397), built here over
  the closed world's own native sources (`ClosedWorld#native_paths`);
* each outside Ruby definition of `n`, by full lexical path. `OutsideRubyOwners` (new,
  `tools/bc2cpp/outside_ruby_owners.rb`) records `Foo::Bar`, and `Foo.singleton` for `def self.x`,
  `class << self`, `module_function` and `define_singleton_method`. ForeignDefiners keeps only the last segment and
  no singleton definitions, so it can refuse a name but cannot name its owner;
* every class an outside source makes wild (a computed definition, `*_eval`, `prepend`, `refine`).

The site is refused, and keeps its by-name else, in these cases: an owner cannot be named (a registration on a
class expression the map cannot read, a `def obj.x` or `class << expr` on an object the Ruby scan cannot name); the
map has a computed-name registration on an unknown non-core owner; or the map has a native `prepend` or an unparsed
definer form. `BC2CPP_NATIVE_OWNER_MAP=0` turns the map off, and with it this lift; the output is then
byte-identical to master. `=strict` also refuses while mruby core's computed-name forwarders exist, as ADR 0397
does.

Three fixes to `NativeOwnerMap` let it name owners it used to call unknown, and they change only those answers:

1. The call positions were read from the comment-stripped text, while the scopes were built on the text in which
   `struct RClass *` is rewritten to `RClass *`. In `class.c` the offsets drifted into the wrong function.
2. A C++ `namespace { ... }` or `extern "C" { ... }` block was taken as one function body. All of `lib.cxx` was then
   one scope with conflicting `m`/`color` variables.
3. A body's variables now settle to a fixed point over each other (`color = mrb_define_class_under(M, m, "Color",
   ...)` after `m = mrb_define_module(M, "RGSS")`). A string literal is no longer read as an assignment
   (`"color="`). A variable assigned once from an unreadable expression takes the class of the core field it is
   stored in (`mod = boot_defclass(...); mrb->module_class = mod;`) or the class mruby names after it
   (`mrb_class_name_class(mrb, NULL, bob, MRB_SYM(BasicObject))`).

As a result, `Module#include?`, `Class.new`, the `BasicObject` table and `RGSS::Color#set` / `RGSS::Tone#set` now
have owners.

### Lift the refusal, keep every Ruby-side gate

`CodeGen#guarded_fallback_line` (wrapped by `OutsideOwnerCall`, `tools/bc2cpp/codegen_outside_owner_call.rb`) first
builds the chain as before. Only a site whose else came out `kept: core_or_native` and whose owners are all named is
built a second time, under `ClosedWorld#with_outside_owner_call(name)`. That lift skips only the
`core_or_native` refusal. Installers, unknown definers, singleton and opaque definers, unlisted classes and
method_missing still apply. A site that one of them still keeps dispatches by name under that gate's own reason. A
site that closes gets the call below as its else. ADR 0323's per-class proof and the RGSS lift run first and are
unchanged, so an else that is already a dead nomethod stays one, and the NOMETHOD_REVIEWED keys do not move.

### The else: a call checked against the owners

```
r4 = bc2cpp_owner_call(M, r4, 104, 2, BC2CPP_OWNERS("Array", "File.singleton", "Hash", "String"), mrb_nil_value(), 1, r5);
/* CLOSED_WORLD owner-call: delete */
```

`bc2cpp_owner_call` (symbol_cache.rb) looks the receiver's method up once (`mrb_method_search_vm`, so an iclass
resolves to its module and an origin to its class). Then:

* **Found on a listed owner.** The method is called in the frame mruby's own dispatch pushes:
  `mrb_funcall_with_method`, the patched `funcall_with_block_m` with the lookup already done, which is the
  NATIVE_SINGLETON_CALL mechanism of ADR 0416. A C function reads its arguments through `mrb_get_args` from
  `mrb->c->ci`, and most of these functions are `static`, so a bare call through the `mrb_func_t` is unsound and
  often impossible. The pushed frame is the one ordinary dispatch pushes, so arguments, the block, `aspec`, the GC
  arena and the error unwinding behave exactly as in the old else. Before the call, the checks OP_SEND makes for the
  instruction run at the level CheckedSend gives the site (ADR 0299). Level 2 (an explicit receiver) refuses a
  private or protected method with the VM's message. Levels 1 and 2 raise `ArgumentError` for an attr_reader with
  arguments, and check a raw C function's registered `aspec` (`check_argument_count`). A site that is not a real
  SEND instruction, a SENDB or a keyword send keeps level 0, which is what its `mrb_funcall` did, and its
  arguments go to the frame exactly as that `mrb_funcall` passed them.
  A `Proc#call`-family name on a compiled block is yielded to, as `bc2cpp_funcall_argv` does.
* **Not found anywhere.** The receiver is proven method_missing-free, so dispatch can only raise NoMethodError.
  The call raises it by dispatching, as `bc2cpp_nomethod` does, so the message, `name` and `args` are dispatch's
  own. A dispatch that returns is a violated proof and raises. This is the path nil and other unrelated receivers
  take. It is not a dead site, so it carries no NOMETHOD marker.
* **Found on any other owner.** That is a definer the closed world did not see. The call raises
  `BC2cppGuardViolation` ("closed-world owner violation"), and does not dispatch. It aborts under
  `BC2CPP_NOMETHOD_VERIFY`, as the other violation arms do.

The owners are matched by `mrb_class_name`, with `.singleton` for a singleton class (by its `__attached__`). Matched
class pointers are kept per site and VM (at most 8), so the name test runs once per owner. The cache is reset with
the symbol table.

Every receiver class in the closed world now has a branch: a Ruby class has its chain arm, and an outside class has
a listed owner. The final else is a checked error. No allowlist hides a dispatch, and nothing is switched off.

### Bare sends and the name owner set (NAME_OWNER_SET)

The same fact holds for any by-name send, not only a chain's else: the receiver of `x.name(...)` is an instance of
a class that answers `name`, or the send raises NoMethodError. When the closed world names every such class, the
send has a known receiver set without any receiver proof:

* the owners are the program's Ruby definitions of `name` (the registry, core Ruby included, modules and
  `.singleton` owners as well) plus every outside owner above;
* the set is unknown when a definer is unknown or dynamic (`ClosedWorld#exact_arm_refusal`: an unknown definer, a
  dynamic install, a singleton maker anywhere), when any method_missing class exists (its hook would answer instead),
  or when an outside owner cannot be named;
* at most 16 owners (`NAME_OWNER_SET_MAX`). `to_s`, `[]`, `to_i`, `to_f` and `update` have an unnameable owner in
  wio anyway; the bound keeps a list that is no real fact from becoming one.

`CodeGen#dynamic_dispatch_line` (the one place a by-name call is spelled) emits the owner call over that set instead
of `mrb_funcall`. Every by-name site of such a name therefore becomes the checked call, wherever it is emitted: a
chain's else (whatever its kept reason was), a bare send with no chain (`pack` has one owner, `Array`; `push` has
`Array`, `RPG2k` and `RGSS::ErrorReport.singleton`, since `RPG2k#push` is the scene stack), and the else of the
registered-expression and NATIVE_OWNER_MAP arms (`empty?` after the Array/Hash/String tag arms and the
`Game::MoveRoute` arm). A guard chain whose else became the owner call is no longer counted as kept. Block sends keep
their `mrb_funcall_with_block`. With a single owner the call is one lookup, one pointer compare against the cached
owner, and the frame call; a receiver the flow already proves (FLOW_CORE_DIRECT, the native exact paths) never
reaches this line.

Using the call as a type fact afterwards (after `x.push(v)` returns, `x` is one of the owners) is not built: the
flow facts have no per-register refinement on a call's success to attach it to, and the narrowed set would only
replace another owner call.

### `new` on `self` (SELF_NEW_LEAF)

In a singleton method of class C, `self` is C or any class that inherits the method; in an instance method of C,
`self.class` is one of the same classes. `ClosedWorld#known_subclasses(C)` lists them when the closed world sees
all of them: the declared subclasses (matched by last path segment, as the hierarchy is), and no `Class.new(C)`, no
outside Ruby subclass and no outside native source spelling the name. Then `new(...)`, `self.new(...)` and
`self.class.new(...)` (with Kernel#class the only `class` and no singleton maker) construct directly:

* a leaf C: `bc2cpp_direct_alloc` of the receiver plus C's compiled initialize, no guard;
* known subclasses: one exact-class arm per class, each with the initialize that class's declared superclass chain
  reaches, and a guard violation for any other receiver;
* unknown subclasses: only exactly C constructs directly; any other class takes Class#new by name.

This fixes a wrong construction on master: the implicit-self `new` in a class method of a class with a stable
constant was compiled as an unguarded allocation of that class, so `Kid.make` with `make` inherited from `Base`
returned a Base built by Base#initialize. The keyword construct path (`new(a, k: v)` in a class method, ADR 0426) of
a leaf class now ends its class test in a guard violation instead of a by-name send.

### `Klass.new` in a protected range (NEW_IDENTITY)

`new_receiver_constant_proven?` read the receiver register's reaching definitions with the plain walk, which
refuses any query inside a begin/rescue body. It now retries with the handler-aware walk (the mode CONSTRUCTOR_POOLS
already uses), so `Rect.new(...)` and `Tone.new(...)` in a rescue body (all 13 such fallbacks on master sit in
`_rescue_try` functions) end their class test in a guard violation, not a by-name `new`.

### Constructor overloads (OVERLOADED_CONSTRUCT)

`sig/native/rgss_constructors.rbs` declares each accepted form of `RGSS::Bitmap`, `Rect`, `Color` and
`Tone#initialize` in RBS overload syntax, annotated with its direct path:

| Class | Overloads | Direct path |
| --- | --- | --- |
| Bitmap | `(String filename, ?untyped transparent)` | allocation + the compiled `RGSS::Bitmap#initialize` |
| Bitmap | `(Integer \| Float w, Integer \| Float h)`, the `else` | `rgss::bitmap_new_direct(int, int)` |
| Rect | `()` | `rgss::rect_new_direct(0, 0, 0, 0)` |
| Rect | `(Integer \| Float x4)`, the `else` | `rgss::rect_new_direct(int x4)` |
| Color | `(?Integer \| Float x4)`, the `else` | `rgss::color_new_direct`, defaults 0, 0, 0, 255 |
| Tone | `(?Integer \| Float x4)`, the `else` | `rgss::tone_new_direct`, defaults 0, 0, 0, 0 |

`Integer | Float` is a positional `mrb_get_args` "i"/"f" converts (`mrb_as_int`/`mrb_as_float`: no `to_int` call, the
same TypeError for anything else). Bitmap's String form has no C++ constructor: its loader is the Ruby
`Bitmap#initialize` (search roots, extensions, the asset archive), whose compiled body is the direct path; a second
C++ copy of that search would be one more implementation to keep equal.

`NativeConstructorSigs` audits the file when it is loaded and refuses it on any disagreement: a C initialize's
forms are its `mrb_get_args` formats (the last one the `else`) plus an empty form for an `if (mrb_get_argc(M) ==
0)` branch that reads nothing; its optional defaults are the initial values of the variables the format fills;
the empty Rect's literals are the field initializers of `struct Rect`; Bitmap's Ruby initialize must be the
`kind_of? String` split between `_init_file` ("z|b") and `_init_size` ("ii", the `else`). A direct path must convert
every positional once, in order. At the call site:

* the program's initialize must be the audited one (no Ruby `initialize` on a C-initialized class; Bitmap's from
  the audited file), and `new` must be Class#new (`native_constructor_safe`);
* overloads are filtered by argument count, then by the classes the flow proves (a Fixnum proof is Integer, an
  exact String flow is String); one left is called with no test, otherwise each gets its class test in declared
  order and the `else` form is the last branch, which raises in its own conversion exactly as the native does; a
  count only the compiled initialize can take (Bitmap with one non-String argument) ends there;
* it runs only where the entry-point path of codegen_send.rb would leave a by-name `new`: a count that path does
  not take (Rect.new, Tone.new(a, b), Color.new) or Bitmap's argument tag test. Proven-Integer Bitmaps and the
  four-argument Rect/Tone/Color keep that path.

### Reporting

The closed-world summary prints `OWNER_CALL: N` after the `KEPT` lines. `bc2cpp_owner_call` is counted in
`SymbolCache.send_indices`, so EMBED_GUARD_FALLBACK still sees the symbol as used.

## Consequences

* For the 23 names of the 135 sites, the wio closed world (`bc2cpp_closed_world_outside_srcs('wio', ...)`: 114
  native and 24 Ruby sources) now names every outside owner except `members`. That is 133 of the 135 sites. Some
  examples: `name` is `Symbol` and mrblib `NameError`, `delete` is `Array`, `File.singleton`, `String` and mrblib
  `Hash`, `string` is mrblib `StringIO`, `include?` is `Hash`, `Module`, `Range`, `String` and `Enumerable`, and
  `set` is `RGSS::Color`, `RGSS::Rect` and `RGSS::Tone`. `members` stays kept (2 sites): `Struct.new` registers
  `members` on the singleton of the class it builds, a class this map cannot name. A site whose Ruby side has its
  own open gate stays kept under that gate's reason. How many of the 133 also clear their Ruby-side gates, and the
  resulting `bc2cpp_send` count, are measured by CI's bc2cpp-build job against master. They are not run locally,
  per the project's rule against long local runs.
* The lookup stays: a closed site still does one method-table lookup with mruby's method cache, the same lookup
  dispatch makes. What changes is that its result is checked against the closed world, the ArgumentError and
  visibility checks are the VM's own, and an unknown definer is an error, not a silent call. The call itself
  remains a C call with a pushed frame, at the cost `bc2cpp_send` already paid.
* `NativeOwnerMap`'s fixes also give ADR 0397 (NATIVE_OWNER_MAP arms) answers where it had refused for an unknown
  owner. Those arms only precede a by-name else, so no site loses a fallback because of them.
* Checks (all fixtures, seconds to tens of seconds; in the bc2cpp-build job of build.yml):
  `scripts/bc2cpp/outside_owner_call_check.rb` (chain elses, bare `pack`, two-owner `push`, the `empty?` arms, an
  unnameable native or outside Ruby owner, a method_missing class, the owner map switched off, and the
  compiled-versus-interpreted run with a rogue C definition behind the closed world's back),
  `scripts/bc2cpp/self_new_leaf_check.rb` (a leaf, an inherited class method called through a subclass, and
  `Class.new(C)`, interpreted against compiled), `scripts/bc2cpp/constructor_overloads_check.rb` (the audit and seven
  mismatch worlds, every declared overload's generated path, a reopened Rect). The RGSS natives are not linked into
  the fixture runtime, so the constructors' run happens in the game build; the audit is what ties each declaration
  to the native.
* Bitmap's 39 fallbacks on master: a `mrb_integer_p` tag test with a by-name else. The 2-argument sites now test
  `mrb_string_p` for the file form and end in `bitmap_new_direct`'s conversions; with the Fixnum proof they keep the
  untested entry point. The 13 Rect/Tone fallbacks end in a guard violation. CI's bc2cpp-build measures both.
* Not covered: the diagnostic reports `interface_table_report.rb` and `native_arms_report.rb` still count the
  whole-name `core_or_native` gate. Block sends (BLOCK_FALLBACK) do not reach `guarded_fallback_line` and are
  unchanged. A class collected and its address reused while it sits in a site's owner cache would skip the name
  test for that one site. It would still call the method the lookup found, which is what dispatch calls.
