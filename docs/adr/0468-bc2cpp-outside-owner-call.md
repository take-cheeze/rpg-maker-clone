# 0468. bc2cpp: the core_or_native else calls the named outside owners

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
* Checks: `scripts/bc2cpp/outside_owner_call_check.rb` (new; generated code, three withdrawal worlds and the
  compiled-versus-interpreted run with a rogue C definition behind the closed world's back). These checks now
  expect an owner-call else where they expected `kept: core_or_native`: `closed_world_check.rb` (`x.size`, with
  Array/String/nil receivers added to its run), `native_class_arms_check.rb` (an owner-call else counts as live, and
  `@mixed.count` must be one), `interface_tables_check.rb` (a table miss) and `native_direct_check.rb` (a program
  subclass of an RGSS class).
* Not covered: the diagnostic reports `interface_table_report.rb` and `native_arms_report.rb` still count the
  whole-name `core_or_native` gate. Block sends (BLOCK_FALLBACK) do not reach `guarded_fallback_line` and are
  unchanged. A class collected and its address reused while it sits in a site's owner cache would skip the name
  test for that one site. It would still call the method the lookup found, which is what dispatch calls.
