# 0461. bc2cpp is closed-world only

Date: 2026-10-16

## Status

Accepted

## Context

bc2cpp had two modes. `BC2CPP_CLOSED_WORLD=1` (ADR 0210) compiled a build whose only Ruby is the engine's own: the
RPG2000/2003-only psp, wio and maix builds and the sealed Optcarrot benchmark (ADR 0400). Without it, bc2cpp compiled
an open world: the desktop `host` engine, which also links mruby-rpgxp, mruby-rpgvx, mruby-wolf and mruby-mvjs and
so loads and defines Ruby at run time. A test-only switch, `RPGMAKER_BC2CPP_CLOSED_WORLD_HOST=1` (ADR 0428), built the
desktop engine as a sealed RPG2k-only world.

The open world kept a second set of rules alive in the generator: analyses that skipped or ran weaker without
`NATIVE_SRCS`/`FOREIGN_RUBY_SRCS`, refusals worded "needs a closed world", and fallbacks taken only because the world
might be open. One of them was unsound: INTEGER_CONSTANT_PROOF admitted a constant on a scan of `NATIVE_SRCS` and
`FOREIGN_RUBY_SRCS` alone, and a proven name lets GETCONST feed an unchecked `mrb_fixnum`, which Ruby loaded at run
time can break. The open world is not worth that cost: a program that loads or defines Ruby at run time is served by
the plain mruby build.

## Decision

bc2cpp compiles closed-world programs only.

- build_config.rb adds the `*-compiled` gems under `RPGMAKER_BC2CPP=1` to the single-format builds (psp, wio, maix)
  only. Every other build, the bootstrap host of a cross build included, is the plain mruby build. The root
  CMakeLists.txt no longer lists the compiled gems. `MRUBY_BC2CPP_SKIP_HOST` is gone: the host never carries them.
- `BC2CPP_CLOSED_WORLD` is no longer an option. bc2cpp.rb aborts, before any work, when `BC2CPP_BUILD_NAME`,
  `BC2CPP_BUILD_GEMS`, `NATIVE_SRCS` or `FOREIGN_RUBY_SRCS` is missing, or when `BC2CPP_CLOSED_WORLD` is set to
  anything but `1`. A build that is not a closed world (compiled_gems.rb's violations) is an error in both the driver
  and `bc2cpp_closed_world_env`.
- Removed: `RPGMAKER_BC2CPP_CLOSED_WORLD_HOST`, `BC2CPP_KEEP_HAND_REGISTRATIONS`, the `Bc2cppClosedWorldOption`
  opt-in, the sealed desktop host's maker stubs and `scripts/bc2cpp/strict_hints_verify.bash`, the
  `wio_strip_bc2cpp_stubs` run on `host`, and `OPTCARROT_CLOSED_WORLD` (the Optcarrot benchmark and its probes always
  compile the sealed world).
- In the driver every `closed_world` nil path and every "without NATIVE_SRCS/FOREIGN_RUBY_SRCS" branch is gone;
  the outside-source scans always run. RECORD_HASH_PROOF and RBS_RECORD_TYPES lose the "needs a closed world"
  refusal, RBS_CHECKED_PARAMS the "no outside-world scan" refusal, DECLARED_RETURN_CHECK its unchecked mode.
- INTEGER_CONSTANT_PROOF runs only where `ClosedWorld#constants_static?` holds, and its poison scan covers the closed
  world's outside sources (the target's host and every linked gem) as well as `NATIVE_SRCS` and `FOREIGN_RUBY_SRCS`.
- Checks run every fixture in the wio closed world (`Bc2cppFixtureRuntime.generate` has no `closed:` switch;
  `tools/bc2cpp/wio_world_env.rb` supplies the four inputs to the checks that run bc2cpp.rb directly). The cases
  that only asserted open-world behaviour are deleted.
- CI's `bc2cpp-build` builds the closed-world maix mruby library with `RPGMAKER_BC2CPP=1` (Kendryte toolchain from
  PlatformIO) and runs the type check, in place of an open-world desktop build.

CodeGen keeps its nil-world guards: a core method body compiles with the world withheld (ADR 0264), and the
analysis-only probe and unit fixtures build a CodeGen without one. That is codegen strategy inside a closed world.

## Consequences

The desktop, wasm and Android builds never run generated code; nothing measures bc2cpp on the desktop engine.
The strict-hint verify run of ADR 0428 needs a closed-world target that can run the workloads. Generated code of
the RPG2k builds changes only where INTEGER_CONSTANT_PROOF now poisons a name a host or gem source defines, or
refuses because constants are not static.
