# 0304. bc2cpp registers the accessors a constant-driven attr_* loop installs

Date: 2026-10-01

## Status

Accepted

## Context

`Optcarrot::Config` installs its readers with `OPTIONS.each_value { |o| o.each { |id, opt| next if opt[:shortcut];
attr_reader id } }`. The registry only reads `attr_reader :literal`, so it held no definer of `loglevel`, and
`@conf.loglevel` in `CPU#run` stayed a by-name send: 1,773,013 of the 7,818,761 executed dispatches of the optcarrot
site profile (ADR 0298), 22.7%. ADR 0288 recognizes `define_method` with a literal name only. In a closed world the same
send also made the whole program refuse (`dynamic_install`), withdrawing the proofs that need the installed-name set.

The loop is a fact about a constant, not about the program: the container is a literal built right before the loop, and
the body is a few pure operations. What it installs can be computed exactly, but not guessed: `next if opt[:shortcut]`
leaves `quiet`, `verbose`, `sdl2` and others out, and registering them would turn a NoMethodError into a read of nil
(ADR 0210: a hint that is not proved is not used).

## Decision

`tools/bc2cpp/loop_installers.rb` (`LoopInstallers`) executes the loop. The registry walk collects each
`each`/`each_pair`/`each_value`/`each_key` send in a class or module body whose block tree sends `attr_reader`,
`attr_writer` or `attr_accessor`; once the walk has seen every definition, a forward pass over the body with a concrete
value for each register and constant runs the loop on the literal and registers what it installs as ordinary
`:ivar_accessor` definitions (`MethodDef#site` records the attr_* sends it accounts for).

The interpreter models Symbol, nil, true, false and opaque literals, Symbol-keyed Hash and Array literals, `MOVE`,
branches on known values, `[]`, `key?`, writes into a scratch Hash constant, nested iterations and the attr_* sends.
Any other opcode, receiver, argument or branch on an unknown value refuses the loop, which stays dynamic. A loop is
recognized only when:

- the container was built in the same body, and no call (which poisons its operands and every known constant), constant
  read of an unknown name (const_missing), or unmodeled opcode ran after it was built; a poisoned container is never
  iterated. Mutation after the loop cannot change what it installed and is allowed;
- the body up to the loop is straight-line (no branch, return, handler, or jump target), so the loop runs once;
- the default visibility is public;
- no non-core definition of the iterators, `[]`, `[]=`, `key?`, `freeze` exists on a core owner, nor of `attr_*` anywhere.

`ClosedWorld#scan_send` accepts an attr_* send the registry accounts for instead of refusing globally; every other
computed installer still withdraws the closed-world proofs.

## Consequences

- Measured on optcarrot (180 frames, `Lan_Master.nes`, checksum 59662 = CRuby, same tree before and after): executed
  by-name dispatches 7,818,761 to 6,025,773 (-1,792,988, -22.9%); `loglevel` 1,773,013 to 0; the
  `no_registered_definition/receiver_class_unresolved` category 1,784,121 to 188. Compiled methods 326 to 355 (synthesized
  accessors). Instrumented timings are meaningless and are not reported.
- The optcarrot site is not exact-class: `@conf.loglevel` is now a runtime-class chain (`POLY_SMALL_N`, two definers of
  the name) whose hit arm is a direct ivar read, and in `NES#step` an `IVAR_ACCESSOR`. An exact `Config` for `@conf` was
  not proved: `@conf` comes from a constructor argument, whose class the class pools do not track (ADR 0295). The by-name
  send remains only as the guard's miss arm.
- In a closed world a call of a loop-installed name devirtualizes like a literal accessor's, including the proven
  NoMethodError miss.
- Loops outside the shapes above (a branch before the loop, a computed name, a container from a call or another scope,
  `each_with_index`) are unchanged. The jump-target and handler rules overlap with the branch rule; the check pins them
  with a retry negative.
- `scripts/bc2cpp_loop_installers_check.rb` compares the registered names with what CRuby installs for each positive world,
  pins each negative world (and the closed-world withdrawal), and runs interpreted vs compiled on a full-core, a core-only
  (core-sourced polyfill iterators) and a 32-bit `mrb_int` build. `scripts/bc2cpp_loop_installers_mutation_check.rb`
  breaks each soundness condition and requires the check to fail.
- Residual risks: the class body is assumed to run once (a second run re-installs the same names); user redefinition of
  `Hash#each` etc. outside the compiled sources is out of scope, as for every closed-world proof.
