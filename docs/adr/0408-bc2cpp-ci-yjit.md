# 0408. Enable host CRuby YJIT for bc2cpp CI

Date: 2026-10-12

## Status

Accepted

## Context

bc2cpp repeatedly analyzes large Ruby source worlds in the host build and
nightly fixtures and mutations. The pinned Nix environment already provides
CRuby 3.4.9 with YJIT support, but jobs run with its interpreter by default.

## Decision

Set `RUBY_YJIT_ENABLE=1` on `bc2cpp-build`, `bc2cpp-checks` and `bc2cpp-width`.
Use the existing Nix Ruby, and verify that YJIT is enabled after exporting the
Nix environment. The job environment reaches Rake and its generator subprocesses
without changing their command lines or replacing existing `RUBYOPT` settings.

## Consequences

Host analysis and generation become faster at the cost of JIT memory per Ruby
process. Parallel check groups and Rake still have their existing concurrency
limits. The generated code, target VM, fixture selection and mutation coverage
are unchanged. A Nix Ruby without YJIT now fails the verification step.

On x86_64 Linux with Nix CRuby 3.4.9, `tools/bc2cpp/bc2cpp.rb` over
`closed_world_mrblib_srcs(root)` with `ONLY_OWNERS` set to the rpg2k compiled
owners and `SKIP_UNSUPPORTED=1` produced byte-identical C++ with YJIT on and
off. This uses the full source list with the default open-world proofs; no
closed-world environment or native source overrides were set.

| Host mode | Wall time, two runs | Peak RSS, last run |
| --- | --- | --- |
| Interpreter | 18.85 s, 18.83 s | 369,388 KiB |
| YJIT | 14.93 s, 14.50 s | 431,540 KiB |

The comparison alternated YJIT and interpreter after one warm-up run of each.
That is about 22% less generation time for roughly 61 MiB additional peak RSS.
These measurements isolate host generation and do not predict an equal
reduction in total CI time, which also includes Nix setup, C++ compilation and
native execution.
