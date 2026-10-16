# 0463. bc2cpp: compact generated C++ is the default

Date: 2026-10-16

## Status

Accepted

## Context

Every call site and method bc2cpp emits carries a `//` comment explaining the proof behind it, for example
`// MONO :new -> StringIO, generic direct object construction via mrb_obj_new; standard Class#new/allocate lookup is
proven and #initialize remains ordinary runtime dispatch.` On the wio shipped pass that is 49,192 comments and
5.6 MB of the 21.0 MB of generated C++, all of it written, buffered and read by the C++ compiler in every build.
`BC2CPP_COMPACT_OUTPUT=1` already stripped them, but it was opt-in and nothing set it.

The comments are also an interface. About 60 check scripts and tools match them in the generated C++ (the proof
markers), and some of the generator's own passes read them back. So they cannot simply stop being generated.

## Decision

* The stripped form is the only default. `BC2CPP_COMPACT_OUTPUT` is removed; there is no environment switch.
* `bc2cpp.rb --annotated` (`ANNOTATED_FLAG`, a command-line flag) keeps the comments. Every caller that reads the
  generated C++ passes it: `Bc2cppFixtureRuntime.generator_run` (so every fixture check), the `never_called`,
  `NomethodReviewedProbe`, `TypeCheckRun` and `profile_annotations` runs, the optcarrot probes, and each check that
  spawns the generator directly (including the test-gem rake rules those checks write). The production
  `*-compiled/mrbgem.rake` builds do not pass it.
* The generator still builds every comment, because `CLOSED_WORLD_SELF` counting, the runtime-def offender scan and
  the subtree tables read them in-process; `CompactOutput` rewrites only what reaches stdout, after the instrumenters.
* Three structural comment kinds survive compaction, one line per generated function, because
  `scripts/bc2cpp/hot_profile.rb` reads them from a build's `*_gen.cpp`: the method header
  (`// Owner#name (compiled from irep ...`), the synthesized-accessor header, and the keyword-call marker of a
  required callee.
* The stderr reports are not changed: they are the machine-read channel of every check, and building them costs
  about 0.1 s on the whole engine (`BC2CPP_PROFILE_TIMINGS`: "diagnostics + sidecar writes").

## Consequences

* The engine's generated C++ shrinks by about a quarter (the wio shipped pass: 21,014,948 to 15,616,317 bytes, the
  same code byte for byte once comments are stripped). The rewrite itself costs about 0.1 s.
* The benchmark of record is this PR's CI `bc2cpp-build` duration against master's.
* A new consumer of the comments must pass `--annotated`. A check that forgets it fails, because its marker is gone; it
  does not pass silently.
* `hot_profile.rb` treats a direct `_impl` call that had a preceding reason comment as a required callee now that the
  comment is gone, so a recomputed hot list can only grow.
