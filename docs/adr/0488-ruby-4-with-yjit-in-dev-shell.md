# 0488. Use CRuby 4.0 with YJIT enabled in the Nix dev shells

Date: 2026-10-18

## Status

Accepted

## Context

The flake provided `pkgs.ruby` (CRuby 3.4.9 on the pinned nixpkgs 26.05). CI
and the bc2cpp host tools ran it with YJIT switched on only through
`RUBY_YJIT_ENABLE=1` in the bc2cpp jobs (ADR 0408). Developers who entered the
dev shell got the interpreter only.

The same nixpkgs input also provides `ruby_4_0` (4.0.5). A local comparison on
the full `type_check.rb` run (master, one run each) took 453 s on the sandbox's
Ruby 3.3.6, 429 s on Ruby 4.0.5 and 343 s on Ruby 4.0.5 with YJIT. The three
outputs were byte-identical. Those are single runs, not a benchmark suite.

## Decision

- The default dev shell and the `clang` dev shell use `pkgs.ruby_4_0`. The
  `build` derivation's native build inputs use it too, so the generators run
  under the same Ruby.
- Both dev shells set `RUBY_YJIT_ENABLE = "1"`, so YJIT is on by default for
  interactive work and for `nix develop -c` commands.

## Consequences

- Host analysis in a dev shell gets the faster interpreter and JIT without any
  per-command setting. The generated C++ is unchanged by the comparison above.
- CI's bc2cpp jobs already set `RUBY_YJIT_ENABLE=1` and now run Ruby 4.0 too. The
  verification step that fails on missing YJIT (ADR 0408) still applies.
- Ruby 4.0 is a major version. Any Ruby code that relied on 3.4-specific
  behaviour needs checking; CI runs the full suite to show that.
- The 3.4.9 measurements in ADR 0408 describe the previous Ruby. They are not
  re-measured here.
