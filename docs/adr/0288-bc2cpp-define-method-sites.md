# 0288. bc2cpp treats a class-body `define_method(:name) { }` as a method definition

Date: 2026-09-30

## Status

Accepted

## Context

Every `define_method` made its name an "installed name" (`CodeGen#symbol_installed_names`), and a
computed one (or `send(:define_method, ...)`) made the set unknowable, which withdraws the
devirtualizations that depend on it program-wide (`BLOCK_CORE_DIRECT`, NativeCoreDirect, proven misses,
class-return proofs; see the "dynamic installer withdraws every arm" assertions). A literal
`define_method(:x) { |a| ... }` in a class body is, for the registry, the same fact as `def x(a)`: a
named method on a known owner with a known arity. It only costs the name, yet the registry never saw
it, so a call to `x` could not be devirtualized.

mruby's `Module#define_method` (src/class.c) copies the block as a method proc flagged
`MRB_PROC_STRICT`: arguments are checked like a lambda, `self` is the receiver, visibility is public.
The class body still executes the call in the interpreter, exactly as it executes a `def`'s `TDEF`;
the compiled entry is registered afterwards over it (`emit_owner_registrations`).

## Decision

`tools/bc2cpp/define_method_sites.rb` (`DefineMethodSites`) recognizes one shape and the registry records
it as a `MethodDef(installer: :define_method)` whose body is the block's irep. A site qualifies when all
hold:

- it is `define_method(:literal) { ... }` sent with an implicit receiver, `LOADSYM`, `BLOCK`, `SSENDB`
  adjacent (no EXT widening), directly in a class or module body of the engine's own Ruby (not a
  singleton-class body, not a block such as `Class.new { }` or `2.times { }`, not mruby's core Ruby);
- the default visibility at that point is public;
- no jump or handler range spans the site, so it runs exactly once per body execution;
- the block starts with `ENTER` and has required parameters only (strict arity then matches `def`);
- the block and its nested blocks reach nothing outside their own frame: no `GETUPVAR`/`SETUPVAR` past the
  block itself (a class-body local), no `RETURN_BLK`/`BREAK`/`BLKPUSH`/`SUPER`/`ARGARY`, no definition or
  class opcode (`TDEF`, `CLASS`, `EXEC`, `ALIAS`, ...), no `block_given?`/`binding`/`local_variables`/
  `__method__`/`caller`. (`return` in a proc method is a `LocalJumpError` in mruby when nested in a block, which is one
  reason it is refused.)

`DefineMethodSites.settle`, called by `bc2cpp.rb` once the closed world exists, then keeps the candidates
only if `ClosedWorld#define_method_sites_trusted?` holds (closed world, no global refusal, nothing that
could rename, wrap or redefine `define_method`: a registry/unknown/outside definition of the name, an outside
native registering it, an `alias`/`undef`/`LOADSYM :define_method` anywhere) and the `(owner, name)` has no
other body (a `def`, a second `define_method`, a `module_function` copy), since which one wins depends on
execution order the registry does not model. A dropped candidate is an installer again, so `symbol_installed_names`
skips a site only when `DefineMethodSites.settled?` finds its registry definition.

Everything else keeps today's behaviour: computed or String names, `send(:define_method, ...)`,
`define_singleton_method`, singleton `define_method`, optional/rest/keyword/block parameters, blocks that
close over locals, `return`/`break`/`yield`/`super`, conditional or repeated installs. No bytecode is
rewritten and nothing is emitted for the registration itself.

## Consequences

- Calls to a recognized method are MONO/POLY like a `def`'s, its body is compiled, and a call from one
  define_method body to another is direct. `scripts/bc2cpp_define_method_sites_check.rb` pins the generated code, each
  negative (shape rejections and settle withdrawals, mutation-checked), and runs interpreted vs compiled on real mruby
  with the VM's argument-count check (strict arity), `next`, ivars, inheritance and override.
- Measured on this tree: the engine's literal class-body sites are zero (the two `define_method` uses in
  `mruby-rpgxp`/`mruby-rpgvx` `rgss_data.rb` loop over a table with a computed name, and optcarrot has none), so the
  slice changes no real build today; it is for code written in this shape from now on.
- Other passes still treat a `define_method` send conservatively (`DynamicNames` keeps the literal name in its
  stems, `numeric_aliased_names` and the numeric ivar self-rebinding scan still poison), so some proofs stay
  refused for these names. That loses precision, not soundness.
- Residual risks: (1) A `def` and a `define_method` of one name in one class are left as before: the
  define_method candidate is withdrawn and a call binds to the ordinary `def` whichever runs last (a pre-existing
  gap, not widened here). (2) The compiled method replaces the proc
  only where registration runs; an unregistered one (static dispatch, hot-only) stays the strict proc, which is
  equivalent. (3) `Method#source_location`, backtrace frames and `__method__`-free introspection differ as for any
  compiled `def`. (4) The trust test is lexical; a `define_method` redefinition inside Ruby outside the build's
  sources is out of scope, as for every other closed-world proof.
