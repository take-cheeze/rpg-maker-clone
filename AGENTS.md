# Project Guidelines

## Documentation Requirements

-   Update relevant documentation in /docs when modifying features
-   Keep README.md in sync with new capabilities
-   Record changelog entries as fragment files in `changelog.d/`, **not** by
    editing the `## [Unreleased]` section of `CHANGELOG.md` directly. Add one
    `changelog.d/<slug>.<category>.md` file per change so branches never
    collide on the same lines. See `changelog.d/README.md` for the format;
    `scripts/build_changelog.rb` folds the fragments into `CHANGELOG.md` at
    release time.

## Pull Requests

Every change lands on `master` through a pull request — do not push to `master`
directly. Before opening one:

- **One logical change per branch/PR.** Keep the diff focused; unrelated
  cleanups belong on their own branch so reviews and reverts stay clean.
- **Branch naming.** Work on a `claude/<short-topic>-<suffix>` branch (matching
  the existing `claude/rpg2k-todos-nftv59`, `claude/mv-move-smoke-e6qtsr` history),
  create it if it does not exist, and never push to a branch you were not asked
  to use.
- **Format before committing.** Run pre-commit after finishing edits so
  `clang-format`, `cmake-format`, `nixfmt`, trailing-whitespace and
  end-of-file-fixer all pass (`pre-commit run --all-files`, or install the hook
  with `pre-commit install`). CI and reviewers expect an already-formatted diff.
- **Add a changelog fragment.** Drop one `changelog.d/<slug>.<category>.md` file
  per change instead of editing `CHANGELOG.md` (see the Documentation
  Requirements above and `changelog.d/README.md`).
- **Check the labels.** A pull request is labelled from its changed paths
  automatically (`.github/labeler.yml`), but the rules skip the mixed files —
  add the `engine:`, `platform:`, `component:` and `type:` labels the diff
  really carries. `docs/labels.md` explains the taxonomy; the labels themselves
  are defined in `.github/labels.yml`, and adding one there is a normal part of
  a pull request.
- **Record an ADR when the change is architectural.** New dependencies,
  patterns, integrations or schema changes get a `docs/adr/` entry (see below),
  and user-facing capabilities get matching `/docs` and `README.md` updates.
- **Run the tests you touched.** Build and run the Google Test / CTest suite
  (`cmake --build build -t test`) and any relevant `scripts/*_check.rb`
  validators before pushing.
- **Open a PR when there is code to review.** Push with
  `git push -u origin <branch>`, then open a pull request whenever the change
  includes code that needs review. A PR must keep CI green before it is merged;
  pushes to `master` deploy the page to **GitHub Pages**. A **Cloudflare Pages**
  preview is published on request — comment `/preview` on the PR when a
  reviewer should see the change running in the browser (see
  `docs/deploy.md`).
- **Auto-merge counts as approval — keep moving.** When a PR has auto-merge
  enabled, treat it as already review-approved: do not block waiting for the
  merge to land. Move straight on to the next task if there is work left to do;
  the PR merges itself once CI passes.
- **Resolve conflicts when you find them.** When a branch or PR has merge
  conflicts against `master` (a push to `master` made the PR un-mergeable, or a
  merge/rebase stops on a conflict), resolve them yourself rather than leaving
  them: merge the latest `master` into the branch (or rebase onto it, per the
  branch's convention), fix the conflicted files, re-run the checks you can, and
  push. Only ask when a conflict is genuinely ambiguous — both sides changed the
  same logic and picking one silently drops behavior.

## Architecture Decision Records

Create ADRs in /docs/adr for:

-   Major dependency changes
-   Architectural pattern changes
-   New integration patterns
-   Database schema changes
    Follow template in /docs/adr/template.md

## Code Style & Patterns

- Codes are formatted by precommit. Please run it after code edit finishes
- Most dependencies are managed by nix flake. See flake.nix for detail

### mruby stdlib methods live in core `*-ext` mrbgems — depend on them

mruby's base classes are deliberately minimal; many methods you expect from
CRuby live in separate **core mrbgems** (`mruby-array-ext` for `Array#-` /
`#difference` / `#compact` / …, `mruby-numeric-ext` for `Integer#zero?`,
`mruby-hash-ext`, `mruby-string-ext`, `mruby-enum-ext`, …). If your Ruby uses
such a method, **do not hand-roll a workaround** (e.g. `reject`/`==` instead of
`-`/`zero?`) — use the real method and make sure the providing core gem is
present:

- **Declare it in the gem that uses it.** Add `add_dependency '<gem>'` to that
  gem's `mrbgem.rake` (see `mruby-mvjs/mrbgem.rake` depending on
  `mruby-array-ext`). This is what makes the method available in the gem's own
  **test** build — the per-gem `rake test` binary only pulls the gem plus its
  declared dependencies, so a method that works in the full game build can still
  be "undefined method" in CI's `mruby_test` if the dependency is not declared.
  This exact gap produced `undefined method '-' for Array` for MZ.
- If the whole game needs it too, it also belongs in the shared list in
  `build_config.rb` (`rpg_maker_gems`) — but the gem-level `add_dependency` is
  the part that keeps the tests honest, so prefer to always add it there.

### `mrb_int` is 32-bit on the cross targets — keep bignums out of C conversions

The native build's `mrb_int` is 64-bit, but the Emscripten (browser), Wio and
PSP builds are 32-bit, so anything past `0x7fff_ffff` becomes an mruby-bigint
there. Arithmetic on a bignum is fine; **handing one back to a C function that
needs an `mrb_int` is not** — that raises `RangeError: integer out of range`.
`Array#pack` is the trap this hit: `[ret].pack('L')` is the natural way to
reinterpret 32 bits as signed, works on the 64-bit build and CI, and raised on
every negative LCF number in the browser (see `LCF.read_ber`). Do the masking
and the wrap with plain arithmetic instead:

```ruby
v &= 0xffff_ffff
v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
```

Nothing in CI runs a 32-bit-`mrb_int` build, so these bugs pass every check and
only show up in the deployed page. When you touch a codec, reason about the
32-bit case by hand.

A second, easier-to-miss trap in the same area: **spell a >32-bit constant as
a literal, not a computed shift/OR expression**, even when every operand of
that expression individually fits in 32 bits (`1 << 32`, `1 << 31`,
`(0xDEAD << 16) | 0xCAFE`). mrbc constant-folds a shift or OR whose operands
are both compile-time literals, and the bignum-pool entry that folding
produces does not survive being cross-compiled by this project's own
64-bit-`mrb_int` host `mrbc` and then loaded by a 32-bit-`mrb_int` target VM:
`mrb_load_irep_file` on the 32-bit side fails to load the *whole compiled
gem* with `ScriptError: irep load error`, before any of that gem's code —
called or not — ever runs. This silently broke `psp-smoke` in production:
`mruby-lcf` (loaded right before `mruby-rgss` in every build's gem-init
order) failed to load, so `mruby-rgss`'s own init never ran, and the actual
symptom several frames later was an unrelated-looking `NameError:
uninitialized constant RGSS`. A bare literal (`0x1_0000_0000` instead of
`1 << 32`) does not have this problem and is just as loadable on every
target — use that, even for a module/class constant meant to replace a
per-call literal (the "computed once, at load time" win only needs the
constant hoisted out of the hot method, not the value itself computed via
an expression).

## Error Handling

- Do not silence errors. Never swallow an exception (or ignore a failing
  return value) so that a failure disappears without a trace.
- When you catch an error to keep the game running (e.g. a missing asset or
  optional data field falling back to a default), still surface it — log it to
  `$stderr` with a `[RPG2k]`/`[RGSS]` tag and the underlying `e.message`, the
  way the rest of the runtime code already does. A recovered error should be
  visible in the log, not invisible.
- Prefer catching the narrowest exception you can. Avoid bare `rescue` /
  broad `rescue StandardError` when a specific class expresses the real
  failure you are recovering from.

## Testing Standards

- Unit tests are written using Google Test and executed by CTest. Use `cmake --build build -t test` to run it
- Line coverage of the Ruby engine sources comes from the host-side checks:
  `ruby scripts/coverage_report.rb` runs the `scripts/*_check.rb` harnesses
  under CRuby's `Coverage` stdlib and reports `mruby-*/mrblib` per gem and per
  file (`coverage/lcov.info`, `coverage/coverage.json`). It measures only what
  those CRuby harnesses reach — `mruby_test` and the native smoke tests run
  inside mruby, where there is no `Coverage` — so the total is a floor, not a
  ceiling. When adding a check to the `ruby-checks` CI job, add it to the
  reporter's `CHECKS` list too, or its coverage goes unmeasured. See
  `docs/coverage.md` and ADR 0049.
