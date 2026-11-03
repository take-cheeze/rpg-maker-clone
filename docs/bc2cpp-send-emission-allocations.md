# Checked-send emission allocations

`CheckedSend#compile_send` (`tools/bc2cpp/codegen_checked_send.rb`) marks the
by-name call of a real `SEND` / `SSEND` instruction so that SymbolCache gives
it a visibility- or arity-checked slot (`CHECKED_SEND`). The lower layers emit
`mrb_funcall(M, RECV, "name", ...)` or
`bc2cpp_owner_call_named(M, RECV, "name", 0, ...)`, and CheckedSend then
rewrites that text to `bc2cpp_funcall_explicit` / `bc2cpp_funcall_noarg` or to
the owner call's check level `2` / `1`.

## Why the rewrite stays a rewrite

Passing the check level down so the lower layers emit the final text directly
would touch about 38 `mrb_funcall(M, ...)` emitters. It would also change what
the intermediate layers of the prepend chain see: several of them inspect the
emitted line for `\bmrb_funcall(` (for example `ArgShapeCalls`, the nilable
receiver dispatch count and the send reports) and would classify a marked call
differently. The textual rewrite at the outermost layer keeps those decisions
unchanged, so this change keeps the design and removes only its waste.

## What changed

The rewrite built two interpolated `Regexp` objects per marked site, escaped the
receiver and name for each, and ran two `gsub` calls. Each `gsub` copied the
whole line even when nothing matched, and each match allocated `MatchData` and a
block result.

The rewrite now:

- skips each step unless the line contains the constant `mrb_funcall(M, ` or
  `bc2cpp_owner_call_named(M, ` prefix;
- finds the exact call head with `String#byteindex` and checks the preceding
  byte for an ASCII word character, which is what the old `\b` tested;
- returns the line itself when no head matches, and otherwise appends the
  slices and replacements to one new String.

A non-ASCII byte before a candidate falls back to the old `Regexp`, whose `\b`
is Unicode-aware. The host section of `scripts/bc2cpp/outside_owner_call_check.rb`
compares the new rewrite with the word-bounded `gsub` on 2,000 seeded random
lines that mix matching heads, identifier and non-ASCII prefixes, near misses
and a non-ASCII method name.

## Evidence

The sealed Optcarrot workload from
[compiler profiling](bc2cpp-compiler-data-profile.md), Ruby 4.0.5 with YJIT,
mrbc built from the pinned mruby `93f276a8f`.

An object-mode profile of master attributed 1,617 direct samples (1.0%) to
`CheckedSend#compile_send`, plus 351 to its `String#gsub` and 265 to
`Regexp.escape`. After the change the method has 281 direct samples and
`replace_call_head` 67; no `gsub` or `Regexp.escape` remains under it.

One warm-up run per version, then three alternating unsampled (`--mode none`)
runs:

| Run | master allocations | this change | master s | this change s |
| --- | ---: | ---: | ---: | ---: |
| 1 | 15,288,054 | 15,103,819 | 7.94 | 8.50 |
| 2 | 15,287,857 | 15,103,728 | 8.54 | 8.42 |
| 3 | 15,287,853 | 15,103,827 | 8.93 | 8.22 |

That is about 184,000 fewer allocated objects (1.2%) per compilation. The
elapsed times overlap, so no speed change is claimed. The generated C++ is
byte-identical in every pair once the per-run temporary world path (plain and
hex-encoded) is normalized.
