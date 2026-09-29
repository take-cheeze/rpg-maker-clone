# 262. Paths the compiler proves impossible raise instead of falling back

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0210, 0252 and 0253 already turn the `else` of a guard chain into
`bc2cpp_nomethod` whenever the closed world proves no other class answers the
name. An audit of what is left found three kinds of silent "cannot happen"
handling:

- generated code: the tail of every function, `return mrb_nil_value(); //
  unreachable`, would hide a compiler bug that let control fall off a body, and
  `bc2cpp_nomethod_argv`, after dispatching and finding a method, raised
  `NoMethodError`, indistinguishable from a user's own mistake;
- the compiler: the outside-source readers (`native_names.rb`,
  `integer_constants.rb`, `native_construct_schema.rb`, `const_site_cache.rb`)
  did `rescue StandardError; next`, so an unreadable file silently
  under-collected a poison source, and `IntegerConstants` answered "not proven"
  for an unknown definition kind or opcode;
- the runtime Ruby: 15 broad `rescue StandardError` blocks returned a default
  with no trace, 20 more caught `StandardError` where only an undefined
  launcher constant (`NameError`) is recoverable, and 14 `rescue` modifiers
  read record fields.

The 379 `core_or_native`, 172 `singleton_definer`, 2 `opaque_definer` and 2
`unlisted_class` guard fallbacks that remain in the wio build are not dead: a
native or singleton definer really can answer, so they keep their dispatch.

## Decision

- **Fall-off tails** (`CodeGen#fell_off_end`) raise `RuntimeError: bc2cpp:
  <method> fell off the end of its body`. All 2,833 tails in the shipped build
  directly follow a `return`, so GCC drops them and the code is unchanged.
- **`bc2cpp_nomethod`** still dispatches first, so a proven-absent method raises
  the ordinary `NoMethodError`; if the dispatch finds a method, it raises
  `RuntimeError: bc2cpp: closed-world proof violated: Class#name ...`.
- **`SourceText.read`** replaces the four readers' `rescue StandardError`: a
  missing path (an uninitialized submodule, not part of the build) is skipped
  with one `[bc2cpp]` stderr line per path; any other `SystemCallError` raises
  `SourceText::Unreadable`. `const_site_cache.rb`'s existing warn-and-give-up
  handlers are narrowed to `SystemCallError`.
- **`IntegerConstants`** raises `ArgumentError` on an unknown kind or opcode.
- **mrblib**: launcher-constant probes rescue `NameError` only; the other broad
  rescues keep their fallback but report `[RPG2k]` on `$stderr` (`RGSS.warn_once`
  in the two per-frame sites); `Scene::Map#record_value` replaces the rescue
  modifiers. `scripts/rpg2k_closed_world_lint_baseline.txt` loses the 14
  entries. A rescue with several classes is not used: bc2cpp does not compile
  the multi-class `EXCEPT` form.
- `scripts/impossible_as_error_check.rb` (ruby-checks, `coverage_report.rb`)
  fails on a broad mrblib rescue that does not report or a new rescue modifier;
  `scripts/bc2cpp_impossible_as_error_check.rb` (bc2cpp-checks) runs the emitted
  helper against a real mruby core for both errors.

## Consequences

- The digit-masked line multiset of the shipped output differs only by the tail
  lines, the helper text, and the mrblib edits (one more compiled method, 26
  more `puts` sends for the log lines; wio strips the `$stderr.puts`).
- A recovered runtime error is visible; an error in a `NameError`-only probe
  that is not a `NameError` now propagates instead of yielding the default.
- Every `rescue` in the compiled mrblib now has to name what it recovers from
  or report it; new silent ones fail CI.
- Residual risk: a data-error path that used to fail quietly (the 15 reported
  sites) may now log repeatedly if a game hits it every frame outside the two
  `warn_once` sites; that is the intended signal.
