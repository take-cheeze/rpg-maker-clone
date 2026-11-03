# Line-pass allocations in bc2cpp

The bc2cpp compiler rewrites each method's C++ text in a few whole-text passes.
Two of them split the text into one String per line and then kept nearly all of
those lines unchanged. This change makes them work with byte offsets instead. It
also removes some small per-call allocations that showed up in the same profile.
The generated C++ does not change.

Sites were chosen from an object-mode profile of the sealed Optcarrot compile.
See [compiler data profiling](bc2cpp-compiler-data-profile.md). Stackprof's
frame `:edges` identified the caller of each allocating leaf. The sample counts
below come from that profile, which records one sample per 100 allocations. The
base profile had 62,116 samples in total.

## Changes

- **`CodeGen#drop_dead_statements`** (codegen_method.rb). The pass used
  `each_line`, which created a String for every line of every method (680
  samples). It now finds each line's end with `byteindex`. A `StringScanner`
  placed at the start of the line runs `DEAD_LABEL`, `SELF_COPY`, `BLANK_LINE`
  and `STATEMENT_END`, so testing a line does not create a String for it. The
  four patterns lost their `\A`/`\z` anchors and now end at the line's newline
  or at the end of the text. This matches where `each_line` splits. If no line
  is dropped, the input String is returned; that String is the fresh result of
  `drop_unused_registers`. Otherwise the text between dropped lines is copied in
  slices.
- **`OwnerCallDirect.rewrite`** (owner_call_direct.rb). The pass used
  `code.lines` with `each_with_index`, and it ran `sub` on every owner-call
  line, including lines it left unchanged (about 530 samples). It now jumps from
  one `BC2CPP_OWNERS(` to the next with `byteindex`. A rewritten line is built
  from the `SITE` match's pre- and post-match. The rest of the text is copied in
  slices.
  `guard_chain_classes` still indexes lines backward from the `} else {`. Its
  input is now `OwnerCallDirect::Lines`, which records line starts only up to
  the last call site that was looked up. When asked for a line it returns the
  rewritten copy if `rewrite` replaced that line, and otherwise slices the line
  from the text. A guard walk therefore sees earlier rewrites at the same
  indices as before, without splitting the whole method.
  `static_dispatch_registrations.rb` still passes it a plain Array.
- **`CodeGen#native_arg_types`** (codegen.rb) allocated a new all-nil Array for
  every method that has no retyped argument (432 samples). Such a method now
  gets a shared frozen Array for its length. Methods with retyped positions still
  get their own Array, built from master's per-label position index. None of the
  callers modify the result: they use `+`, `[]`, `any?`, `all?`, `compact` or
  `each_index`.
- **`CodeGen#direct_call_args`** (codegen_send.rb) collects the positions it
  unboxed with `each_index` instead of `each_with_index`. The latter allocated
  through Enumerable (198 samples).
- **`RegisterFlow#info_for`** (register_flow.rb) tests `CLEAN_DEF` with
  `match?`. It reads the register number from the digit bytes and slices out
  only the expression. Before, every defining line created a MatchData and two
  captured Strings (about 240 samples).
- **`CodeGen#strict_hint_wrap`** (codegen_send.rb) compiled a Regexp from the
  escaped dispatch line on every call so that `gsub` could use it.
  `strict_kept_replace` now finds each leftmost occurrence of the dispatch line
  with `byteindex`, along with the kept marker if one immediately follows it.
  `gsub` matched the same spans.
- **Loop-region layouts** (codegen_loop_regions.rb, codegen_step_loop.rb,
  codegen_array_new_inline.rb). Eight recognizers built their `layout` lambda,
  and `recognize_accum_regions` also built `accum_kind`, on every call per
  irep. Each lambda reads only the instruction, so each is now a constant. The
  accum layout also built a `{ pred: 1, fold: 2 }` Hash for every instruction;
  that Hash is now a frozen constant. `proven_array_source` keeps its two
  oracles, which read only this CodeGen's facts, in instance variables. Its
  `receiver_class` lambda captures the irep and is still built for each call.

Two candidates were tried and dropped because the profile did not change.
`indent_lines` was given a single-line fast path (172 to 189 samples), and the
`OutsideOwnerCall#guarded_fallback_line` marker `sub` was skipped when the base
line had no marker (1,746 to 1,767). Most of their calls are multi-line or
contain a marker, and for those inputs `gsub`/`sub` already allocate the
minimum. The `dispatch.sub(/\n\z/, ...)` in `CodeGen#guarded_fallback_line` was
also left alone. In a micro-benchmark, `dup` + `insert` allocated the same two
objects.

Frame totals in object samples, measured on the branch's first base (`8b208c5cc`):

| Frame | Base | Change |
| --- | ---: | ---: |
| `CodeGen#drop_dead_statements` | 738 | 68 |
| `OwnerCallDirect.rewrite` | 534 | 224 |
| `CodeGen#native_arg_types` | 432 | 0 |
| `CodeGen#direct_call_args` | 856 | 434 |
| `RegisterFlow#info_for` | 499 | 261 |
| `CodeGen#strict_hint_wrap` | 2,176 | 1,967 |
| the eight recognizers plus `proven_array_source` | 902 | 482 |

## Equivalence

- The generated C++ and the compiler log are byte-identical to the base once
  the per-run temporary paths are normalized, plain and hex-escaped. This holds
  for the compact output (all six runs below) and for `--annotated` output, on
  both bases.
- A hook prepended to the real compile ran master's version of each changed
  text pass next to the new one on every call and compared the result and its
  encoding. There were no mismatches:

  | Pass | Calls |
  | --- | ---: |
  | `drop_dead_statements` | 560 |
  | `info_for` | 10,531 |
  | `strict_kept_replace` | 1,616 |
  | `OwnerCallDirect.rewrite` | 447 |

- A seeded random comparison ran 30,000 cases per pass under each of three
  seeds, on generated text built from the shapes each pass looks for:
  - dead labels, self copies, blank and NUL lines, unbraced `if`/`case` heads,
    UTF-8 and BINARY text, and a missing final newline;
  - guard chains of exact-class, `mrb_likely` and RGSS native arms with
    owner-call sites, subclassed and non-closed owners;
  - kept markers, including malformed ones, and backslashes in the replacement.

  There were no mismatches. In about 60% of the cases, master's result differed
  from its input.

## Measurements

Sealed Optcarrot compile, `scripts/bc2cpp/compiler_profile.rb --mode none
--optcarrot`, on Ruby 4.0.5 with YJIT, against master `82b93ceff` (after #3103
and #3105). Each version had one warm-up run, then three alternating runs per
version on the same host:

| Run | Version | `allocated_objects` | `elapsed_seconds` |
| --- | --- | ---: | ---: |
| 1 | master | 5,241,406 | 6.241 |
| 1 | this change | 5,008,684 | 6.342 |
| 2 | master | 5,241,234 | 6.301 |
| 2 | this change | 5,008,726 | 6.283 |
| 3 | master | 5,241,443 | 6.429 |
| 3 | this change | 5,008,742 | 6.396 |

Allocations fell by about 232,600 objects per run (4.4%). Within each version,
runs differed by fewer than 210 objects. On the first base, `8b208c5cc`, the
same comparison went from 6,214,244–6,214,365 to 5,974,699–5,974,719 objects,
a 3.9% drop. Elapsed time did not move consistently, so this change claims no
speedup.
