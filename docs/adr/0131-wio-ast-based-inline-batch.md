# 131. An AST-based rewrite of the single-caller inliner, rebuilding the batch ADR 129 abandoned

Date: 2026-09-10

## Status

Accepted

## Context

ADR 129 hand-verified 18 single-caller `mruby-rpg2k` helper methods, then tried
to automate the same transform across the ~166-method candidate pool it had
found, and stopped after four rounds of real bugs: a classifier that recorded
a def's own line as its call site, a naive substring search that matched a
`:symbol` literal as if it were a real call, multi-line call continuations
and `rescue`/`ensure` bodies corrupting the flattened splice, and a
`Open3.capture2` stdin-encoding bug in the verification harness itself. All
of the first three are the same underlying problem: **text/token scanning
does not know where one Ruby construct ends and another begins.**

`RubyVM::AbstractSyntaxTree` (stdlib since Ruby 2.6, present in every
CRuby this project runs `scripts/*.rb`'s regression checks with) gives real
per-node `first_lineno`/`first_column`/`last_lineno`/`last_column`, and real
node types (`CALL`/`FCALL`/`VCALL` vs `LIT` holding a `Symbol`; `RESCUE`/
`ENSURE`/`WHILE`/`UNTIL`/`FOR`/`ITER`/`RETURN` by type, not by grepping for
the English word). A quick proof-of-concept against the exact three bug
classes above (the real `:battle_row` collision in
`mrblib/scene/status_menu.rb`, a real multi-line `attr_reader` in
`interpreter.rb`, and the 8 real `rescue`-bearing methods in
`interpreter.rb`) confirmed each is a non-issue once location-finding goes
through the AST — see the chat transcript around this ADR's own date for the
three checks. This ADR is the resulting rebuild.

## Decision

**Rebuilt the candidate pipeline on `RubyVM::AbstractSyntaxTree`, scoped to
the same 14 `mruby-rpg2k` files `wio_rbfiles.txt` already covers** (this is
*not* a change of scope from ADR 129 — `mruby-rgss`, `mruby-lcf`, mruby's own
core `mrblib`, and any C code are untouched; see "What this does not touch"
below):

1. Index every `DEFN` and every bare (`FCALL`/`VCALL`) call site across all
   14 files. Filter to names with exactly one definition and exactly one
   bare call site anywhere (509 such names).
2. Classify each candidate's body by real AST node type: 265 have a
   loop/`yield`/`rescue`/`ensure`, or a `return` outside guard-clause shape
   (left alone, same as ADR 129); 194 have no `return` at all ("flat");
   50 have `return` confined to leading `if`/`unless` guard clauses with
   the rest of the body unconditional ("guard") — a new category ADR 129
   never reached, since its rule explicitly excluded any `return`.
3. **Flat candidates**: splice the body as `(stmt1; stmt2; ...)` at the one
   call site, using the AST's own exact source span for each statement
   (handles multi-line statements for free — no line-counting).
4. **Guard candidates**: convert `return E if C; REST` into an `if`/`else`-
   equivalent. Two shapes, depending on whether the call site's return value
   is actually used (checked by comparing the call node's own span against
   its containing line, not by guessing): value discarded → wrap `REST` in
   `unless (C1 || C2 || ...); REST; end`, dropping the values; value used →
   a paren-wrapped nested ternary `(C1 ? E1 : (C2 ? E2 : (REST)))`,
   preserving the original return value exactly. 38 of the 50 guard
   candidates fell into the value-used case.
5. Every candidate — 83 flat (zero-parameter; 104 more take parameters and
   are deferred, same reasoning as ADR 129's own deferred pool) and all 50
   guard — was tested **individually**: a fresh scratch copy, the transform
   applied, a real `ruby -c` syntax check, a real `mrbc --remove-lv` compile,
   delta against a pristine baseline. All 133 passed with zero syntax
   failures and zero net losses (each real delta ranged −48 to −234 bytes).
6. Checking whether all 133 could ship *together* surfaced three real
   interaction classes that individual testing can't see, all found and
   fixed before anything was written to this file:
   - **21 candidates chain into each other** (A's one call site sits inside
     B's own body — both being inlined at once). Excluded from this batch
     rather than sequenced; safe to revisit but not attempted here.
   - **1 candidate's body calls an ADR 129 method already being inlined**
     (`leave_target_mode` calls `invalidate_items`) — inlining both without
     accounting for the dependency would leave a real dangling call
     (`invalidate_items`'s own definition gone, a plain-text reference to it
     surviving inside `leave_target_mode`'s splice). Excluded.
   - **3 same-line collisions**, two among new candidates
     (`tinting?`/`flashing?` both called on `busy?`'s own one-line body;
     `timer_running`/`timer_visible` likewise) and one against an *existing*
     ADR 129 substitution (`rpg2003_party?`'s only call site is the exact
     line `draw_battle_row`'s own substitution already rewrites). Excluded
     rather than merged.
   - A **real substring-collision bug in the generator itself**: a bare
     call's line text (e.g. `"      draw_arrow"`) is a literal *prefix* of
     an unrelated line elsewhere (`"      draw_arrow_visibility"`), so
     `apply_rewrites`'s plain `String#scan`/`#sub` matched both. Fixed by
     anchoring every substitution's `old`/`new` text to end-of-line (a
     literal trailing newline embedded in the string), verified by checking
     `source.scan(old).length == 1` against the real file before accepting
     a candidate.
7. The final **106** candidates were regenerated as real
   `{first:, last:, expect_lines:}` / `{old:, new:}` entries and appended to
   `strip_wio_inline_helpers.rb`'s existing `REWRITES` — not by hand, but by
   running them through *this file's own, unmodified* `apply_deletion`/
   `apply_rewrites` functions (`require_relative`'d into the generator) and
   a real Ripper parse + `mrbc` compile, so the entries that landed are
   exactly the ones already proven to work through the real mechanism, not
   a second, hopefully-equivalent implementation of it.

### What was verified

Running the real, unmodified `strip_wio_inline_helpers.rb` against all 14
checked-in files (`ruby strip_wio_inline_helpers.rb <in> <out>`, the same
invocation `wio_strip_inline_helpers` drives at build time) succeeds for all
14, every output re-parses (`ruby -c`), and a real `mrbc --remove-lv` compile
of the 14 rewritten outputs together:

```
477,883 -> 465,506 bytes (-12,377, wio-shaped mrbc --remove-lv proxy)
```

(477,883 here is this session's own pristine baseline — the 14 files as
checked in, before ADR 129's 18 methods are folded in by this same
mechanism — not ADR 129's own reported 476,491, which already includes
those 18. The two numbers aren't meant to be compared directly; this ADR's
−12,377 is on top of, not instead of, ADR 129's own reduction.)

### What this does not touch

This is a Ruby-source-level technique scoped to `mruby-rpg2k`'s own 14
`mrblib` files — the same scope `wio_rbfiles.txt` has had since ADR 124.
It does **not** touch:
- `mruby-rgss`'s or `mruby-lcf`'s own `mrblib/*.rb` (a handful of files
  each; the same single-caller/guard-clause patterns likely exist there
  too, just not measured by this pass).
- mruby's own core `mrblib` or any `*-ext` gem's Ruby wrapper — those ship
  as part of vendored upstream `3rd/mruby`, not this project's own gems.
- Any C code. The unrelated idea raised the same session (dropping
  core/`*-ext` mruby methods whose Ruby name is never called anywhere, via
  their `MRB_MT_ENTRY` ROM method tables) is a completely different lever —
  C-level, touching vendored `3rd/mruby` source directly, needing the
  `patches/*.patch` + `apply_mruby_patch.bash` mechanism rather than this
  file's build-time rewrite-a-copy approach. That idea was scoped and
  measured (≈17–21 KB candidate) but not implemented; this ADR is unrelated
  to it.

## Consequences

- **strip_wio_inline_helpers.rb now folds 124 methods total** (18 from ADR
  129 + 106 from this ADR) into their call sites, wio-only, with every
  checked-in definition still intact for `scripts/*.rb`'s own regression
  coverage — same guarantee ADR 129 established.
- **The AST-based generator itself is scratch, not committed** (it lived
  under `/tmp` for this session) — the entries it produced are committed,
  but the tool that produced them is not part of this repo. A future
  session wanting to extend this further (the 104 deferred parameterized
  flat candidates, the 21 deferred chained ones, `mruby-rgss`/`mruby-lcf`'s
  own mrblib) would need to rebuild it, informed by this ADR's own
  candidate-shape numbers and the three interaction classes it found.
- **The interaction-checking step (chained candidates, same-line collisions,
  substring anchoring) is the real deliverable, not just the AST parsing.**
  Location-finding being reliable (this ADR's whole premise) does not by
  itself make a large batch safe to apply *together* — three genuinely
  different classes of cross-candidate interaction existed in this one
  106-method batch, all invisible to per-candidate testing alone. Any
  future extension of this pool needs the same combined-application check,
  not just individually-passing tests.
