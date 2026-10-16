# 0477. A block's self is its creator's: a checked world fact, and an entry check where it fails

Date: 2026-10-16

## Status

Accepted. Extends BLOCK_SELF ([ADR 0456](0456-bc2cpp-checked-rbs-parameters-singleton-optional.md)) and PROVEN_MISS ([ADR 0275](0275-bc2cpp-proven-class-miss-and-nomethod-verify.md)).

## Context

A compiled block body (BLOCK_FALLBACK, `codegen_block_fallback.rb`) reads `self` from its env slot 0. That slot holds
the self of the frame that built the block. Implicit-self sends in the block resolve through `lexical_self_owner`,
as in the method body. Ruby has no way to change a block's self other than a *rebinder*:
`instance_eval`/`instance_exec`, `class_eval`/`class_exec`, `module_eval`/`module_exec` (vm.c `eval_under`,
mruby-object-ext), `define_method`/`define_singleton_method` (the block becomes a method body), and `new` on
`Class`/`Module`/`Struct` or `Data.define` (class.c, struct.c and data.c `class_eval` the block). All of them call
`mrb_yield_with_class` or install the Proc as a method. Nothing checked that a compiled block never reaches one.

The gap was a real miscompile. BLOCK_FALLBACK admits a literal block under any method name, so
`o.instance_exec(3) { |k| [@tag, k] }` compiled the block with the creator's self. The interpreted run printed
`[:target, 3]`; the compiled run printed `[:creator, 3]` and read `@tag` from the creator's embedded ivar struct.
`instance_eval { @tag }` and `class_eval { self }` were wrong the same way.

BLOCK_SELF (ADR 0456) proved a block's self per call site: every callee had to be a plain yielder or a checked
block-return declaration, so a block handed to a native iterator (`Array#each`) got no answer. ClosedWorld refused
`self` for PROVEN_MISS in the whole program as soon as the engine sent any rebinder.

## Decision

**The analysis.** `tools/bc2cpp/block_self_world.rb` (BLOCK_SELF_WORLD) reads every Ruby source of the closed world as
bytecode: the compiled sources, and the outside ones (FOREIGN_RUBY_SRCS and the build's gem mrblibs), which bc2cpp.rb
compiles for this analysis alone. It also scans the outside native sources and NATIVE_SRCS. It answers two things.

* `rebound`: a LITERAL block or lambda (the BLOCK/LAMBDA right before the SENDB/SSENDB that takes it) at a rebinder
  site, and every block nested in it. `new`/`define` count as rebinder sites unless the receiver is a constant naming
  a class whose superclass chain is known (from `class` statements, the registry and
  `sig/native/core_hierarchy.rbs`), never assigned, and free of Class/Module/Struct/Data. So `Array.new(n) { }` is
  not a rebinder site and `Fiber.new { }` is. A computed-name send with a literal block counts unless its name is
  proven.
* The WORLD FACT: no rebinder ever receives a Proc other than such a literal block. It fails (the result's `why`,
  with every failing site in `failures`) on any of these:
  * a rebinder send with a block that is not literal (`&blk`, a stored Proc, a forwarded block register);
  * a Proc argument to `define_method` (or a computed send with two or more arguments after the name);
  * a computed-name send (`send`/`__send__`/`public_send`) or Method maker (`method`, `instance_method`, ...) whose
    name is not proven, when it carries a block;
  * a rebind name spelled as a Symbol or String literal, aliased, or defined in Ruby;
  * a String eval: `eval`, or `instance_eval`/`class_eval`/`module_eval` with arguments and no block;
  * a native outside the rebinders' own implementations (vm.c, class.c, load.c, proc.c, struct.c, data.c, eval.c,
    object-ext, class-ext, metaprog.c, method.c, fiber.c) that calls `mrb_yield_with_class`/`mrb_exec_irep`/
    `mrb_vm_run` and the like, spells a rebind or computed-send name, or passes a block to a method it names by a
    variable;
  * an outside Ruby source mrbc rejects.

  A proven name is a Symbol literal, or the `self` of mruby's `Symbol#to_proc`. That self is one of the Symbols the
  program passes as a block (`&:sym`): every block operand of every send must then be a literal block, nil, a block
  parameter (already a Proc, OP_SENDB converted it) or a Symbol literal, and nothing may send `to_proc` by name.
  This proves `symbol.rb:5` (`obj.__send__(mid, *args, &block)`).

**The wio world may rebind.** It fails at exactly one site. `enumerator.rb:322`, Enumerator#each's
`@obj.__send__ @meth, *@args, **@kwd, &block`, forwards a block that is not a literal under a name read from an
ivar. The rebound blocks are mruby-enumerator's four `instance_eval { }` blocks and its `Fiber.new { }` block. No
engine block is rebound; the engine sends no rebinder.

**Consumers.**

* Code generation. A rebound block is never compiled with a captured self: `recognize_block_fallback_regions`,
  `recognize_lambda_fallback_regions` and `emit_proc_fallback_fn` refuse it, so the method holding it stays
  interpreted. This holds in every world and closes the miscompile above.
* The entry check, emitted only when the world fact fails. A compiled block body compares the self the VM passes
  with its captured one before it runs. For a cfunc proc the VM passes:
  * nil with Object as the target class for a yield (`mrb_yield`/`mrb_yield_argv` through `mrb_proc_get_self`);
  * the proc itself with the proc's own target class for Proc#call (OP_CALL) and OP_BLKCALL;
  * the new self with its singleton class or the module for a rebinder (`mrb_yield_with_class`), where nil's
    singleton class is NilClass, never Object;
  * the receiver with the method's owner for a define_method body, which is a strict copy of the proc that only the
    method table holds.

  The first two, and the captured self itself, pass. Anything else raises `BC2cppGuardViolation` ("closed-world
  guard violation: compiled block of ... run under ... instead of its creator's self"), logged like the other guard
  violations, and the body never runs under the passed self. A define_method body on Object called on nil looks like
  a yield, so for a strict proc a nil self is checked against the method table as well: the body found for the
  current method name must not be the running proc. A direct-entry block keeps the check as bit 1 of its flag env
  slot (bit 0 is YIELD_FREE), so the shared `bc2cpp_block_thunk` stays one function. A compiled yield that calls the
  entry directly needs no check. A non-direct block function emits the check inline. When the fact holds no check is
  emitted and the flag bit is clear. The interpreted program would rebind such a block; the closed-world build turns
  that into an error.
* BLOCK_SELF (`block_self_owner`). When the fact holds, a block's self is its creating method's, walking the nesting
  chain, unless a block on the chain is rebound. The per-callee plain-yielder requirement is dropped. When the fact
  fails, the per-site proof of ADR 0456 is unchanged. The entry check does not count: the type check also speaks for
  interpreted runs. A CodeGen built without the build's scan (a unit check) refuses the fact.
* PROVEN_MISS (`ClosedWorld#proven_miss?`). `self` is refused only inside a rebound block (and when the analysis is
  absent), instead of everywhere once any rebinder is sent. Any other compiled block keeps its creator's self: by the
  fact, or, where the fact fails, by the entry check, which raises before the send.

`ClosedWorld#singleton_makers` is public again: `constructor_pools_refusal` calls it to name the makers it refuses
over, and a fixture with `instance_exec` reached that call and crashed the generator.

## Consequences

The `instance_exec`/`instance_eval`/`class_eval`/`define_method`/`Class.new`/`Struct.new` miscompile is gone: those
blocks stay interpreted. In the wio world every compiled block entered through the VM pays one comparison, plus a
flag test in the thunk. Compiled yields that call a direct entry pay nothing. A compiled block that reaches a
rebinder through a forwarded Proc now fails loudly instead of running with the wrong self. PROVEN_MISS can judge
`self` in engine blocks even if some engine code sends a rebinder with a literal block. When the world fact holds,
BLOCK_SELF answers blocks handed to native iterators.

`scripts/bc2cpp/block_self_world_check.rb` covers:

* the rebound marking, nested blocks included;
* each shape that fails the fact, the native rules and the rebinders' own files;
* the wio world: it fails at enumerator.rb:322 only, symbol.rb:5 is proven, and the rebound sites are listed;
* the consumers in-process;
* the generated code, with no compiled block at a rebinder site and an entry check on every compiled block;
* interpreted-vs-compiled runs on a full-core libmruby: rebinder sites, each/map over Array/Range/Hash, Proc#call,
  `===`, `[]`, `lambda(&b)`, compiled lambdas yielded by an iterator, an interpreted yield, a Fiber, and nil as the
  creator's self. It also covers the violation for a compiled block handed to `instance_exec` or `define_method` as
  `&blk`, including a define_method body on Object called on nil.

It runs in the `bc2cpp-build` job next to the define_method check.

Follow-ups:

* A name-provenance analysis for `@meth` (to_enum/enum_for/`Enumerator.new` arguments, attr writers,
  `instance_variable_set`, Marshal's data-driven ivars) would make the wio fact hold. It would remove the entry
  comparison and give BLOCK_SELF the world answer. It closes no hole: the check already covers it.
* With the fact holding, CORE_SELF_EXACT (`codegen_exact_receiver.rb`, the method's own irep only), the escape
  analysis' block-self refusal (`codegen_escape.rb`) and `outside_ruby_ivar_scopes.rb` could accept non-rebound
  blocks.
