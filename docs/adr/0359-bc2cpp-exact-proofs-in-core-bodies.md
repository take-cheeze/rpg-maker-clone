# 0359. Literal and `*rest` receiver proofs inside compiled core bodies are checked at run time

Date: 2026-10-06

## Status

Accepted

## Context

EXACT_CORE_RECEIVER (ADR 0280) proves a receiver is exactly an Array, Hash, Range or String when a
dominating literal, or the method's own `*rest` slot, supplies it through register copies. The
proof reads `@closed_world`, and a compiled core body (mruby's own Ruby, ADR 0264) is compiled with
`@closed_world` hidden, so every `args.size`, `hash.values` or `ary.empty?` on such a value in
`Array#dig`, `Hash#merge!`, `String#gsub`, `Range#first` and the like keeps the inline Array/Hash/String
tag chain with a by-name send as its else.

Measured on the Wio shipped build (master 0a9adfc), `core_tag_chain_else:receiver_other` was 849
sites, about 190 of them in core bodies, some on a literal or a rest array.

A first version of this change (parked) simply let the existing arms read the program's world
(`block_core_world`). Those arms are *unguarded proofs with no dispatch fallback*: they rest on
`ClosedWorld#exact_instances_singleton_free?` and on a grep of mruby's core Ruby, which the world scan
skips (ADR 0280), so a wrong proof would have been an unchecked access to an object that is not
an Array, not an error.

## Decision

The proof is made for core bodies and **checked**, never trusted.

1. `exact_core_site` keeps the engine world's proofs as they are (unguarded, ADR 0280). Inside a core body
   (no `@closed_world`), `checked_core_body_site` asks `core_body_exact_class` for the dominating-writer walk
   alone (`exact_walk_class`) under the program world (`@core_program_world`). `exact_core_value_class`
   itself, which `ARRAY_PUSH`, `INDEX_EXACT` and the argument proofs call, is unchanged, so none of those
   unguarded arms reaches a core body. The site carries no argument or Fixnum proof (`arg_class` answers nil,
   `int_site` is nil): only the receiver is proven, and only the receiver is tested.
2. `with_exact_core_site` wraps whatever code the arms made from such a site (`CLOSED_WORLD_NATIVE_EXACT`,
   `BLOCK_CORE_DIRECT ... proven`, `CORE_EXACT_DIRECT`, `NATIVE_CORE_DIRECT ... proven`) in one test of the
   receiver register, `mrb_<class>_p(r) && mrb_obj_ptr(r)->c == M-><class>_class`, the test the guarded arms
   use, with `bc2cpp_guard_violation` (ADR 0290) as the else:

   ```
   // CORE_BODY_EXACT_CHECKED :size -> Array (ADR 0359)
   if (mrb_array_p(r5) && mrb_obj_ptr(r5)->c == M->array_class) { <the arm, no dispatch> }
   else { r5 = bc2cpp_guard_violation(M, r5, i, "Array#dig (CORE_BODY_EXACT)", 0); }
   ```

   The violation logs `[RPG2k] closed-world guard violation: <Class>#<name> at <Owner>#<method>
   (CORE_BODY_EXACT)` and raises `BC2cppGuardViolation` (< NoMethodError); `-DBC2CPP_NOMETHOD_VERIFY` aborts.
   A singleton class on the receiver changes `->c`, so the test catches exactly what the singleton-free flag
   assumes away. The proof (a literal or the rest slot) only chooses which sites get the test; it is no longer
   what keeps them sound.
3. `BC2CPP_CORE_BODY_EXACT=0` and `BC2CPP_GUARD_VIOLATION=0` (ADR 0290: every guard keeps its dispatch)
   each restore the old output byte for byte; the closed-world flag still withdraws the proof when
   the program makes singletons.
4. The grep is replaced by `scripts/bc2cpp_core_singleton_audit.rb`: it parses every Ruby source compiled into
   the VM but outside the closed world (`foreign_mrblib_srcs`) and the C sources of the external gems, finds
   each `instance_eval`, `instance_exec`, `singleton_class`, `define_singleton_method`, `extend` (also as a
   symbol), `class << expr` other than `class << self` in a class body, and `def expr.name`, and fails on any
   site that is not in its reviewed list (seven today: `instance_eval` on an Enumerator, a Lazy and a
   TCPSocket, and four `def Const.name`) and on any listed site that is gone. A new mruby that makes
   a singleton anywhere fails CI until it is reviewed. It is not a proof of the receivers it lists (they are
   reviewed by hand and named in the list); the generated test above is what makes a wrong review loud.

## Consequences

Measured on the Wio shipped build, same tree, switch off against on (table in
`docs/bc2cpp-dynamic-site-census.md`): `bc2cpp_send` sites in bodies 2,321 to 2,286 and
`mrb_funcall_with_block` 417 to 414, the same sites the unguarded version removed; the class test is one
pointer compare per site. The cost of making the proofs checked is one test per site and 38 cold `bc2cpp_guard_violation`
sites (35 `CLOSED_WORLD_NATIVE_EXACT` arms in `Array#dig`, `Hash#dig`, `Struct#dig`, `Hash#merge`,
`String#gsub`/`sub`, `Range#first`/`last`, `Enumerable#first`/`uniq`/`cycle`, `StringIO#read_nonblock` and
so on, and 3 `BLOCK_CORE_DIRECT` arms), each listed as `GUARD_VIOLATION_SITE` and counted under the
`CORE_BODY_EXACT` family. The engine's own unguarded arms (ADR 0280) are untouched.

`scripts/bc2cpp_core_body_exact_check.rb` covers it: generated code (every proven core-body site is wrapped,
an engine site is not, a parameter, both kill switches, a singleton-making engine and the open world leave
the tag chain, and no compiled core body keeps an `unguarded proof` arm), and on real mruby an honouring
fixture that answers what the interpreter answers and reaches no violation site (also under
`-DBC2CPP_NOMETHOD_VERIFY`) against a deliberately violated one (the Array class swapped behind the literal,
a compiled body entered with a rest slot that is no Array) that logs and raises naming class, name and site,
and aborts in verify mode. The receivers of unknown origin remain: they need new class sources (ivar pools,
argument pools, element classes), not more copy propagation.
