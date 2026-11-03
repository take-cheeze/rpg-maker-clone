# bc2cpp compiler text allocations

An object-mode profile of the sealed Optcarrot compilation
([compiler profiling](bc2cpp-compiler-data-profile.md)) attributed several
percent of host allocation samples to String churn: captured substrings,
`strip`/`chomp` copies and per-line Strings from `lines`/`each_line`. The
changes below remove the ones that were pure waste. Generated C++ is unchanged.

## Changes

| Site | Samples before | Change |
| --- | ---: | --- |
| `RegisterFlow#mention_mask`, `#mentions` (`String#scan`) | 1,734 | Register numbers are read from the digit bytes after a `StringScanner#skip_until` of the same `MENTION` pattern, instead of one captured String (and one Array) per match. A match ends at a non-word byte, so resuming there sees the same word boundaries `scan` does. |
| `RegisterFlow#transparent?` (`each_line`, `strip`, `lstrip`) | 262 | One `match?` of `OPAQUE_LINE`, a line that has something other than `//` after String#strip's whitespace (NUL included). |
| `CodeGen#drop_dead_statements` (`strip`, `reject`, `join`) | 666 | The blank-line test is a regex over strip's whitespace set, and kept lines are appended to one buffer instead of collected and joined. |
| `CodeGen#compile_method` (`String#+`) | 487 | An instruction's text is concatenated with a guarded-inline prefix only when there is one. The splat-sharing branch already passed the compiled text through uncopied. |
| `ClosedWorld.ruby_file_facts`, `#merge_outside_tokens`, `RbsParamCheck#outside_call_names`, `StaticDispatchRegistrations.outside_world_tokens` (`chomp`) | 565 | `ClosedWorld.token_stem` replaces `chomp('=').chomp('?').chomp('!')`. The tokens there match `[A-Za-z_]\w*[?!=]?`, which ends in at most one suffix, so one `chop` is the same, and an unsuffixed token is not copied. The symbol-name site in `outside_world_tokens` keeps the chain: an operator name such as `!=` has two suffixes. |
| `CoreMixins.definers_in` (`lines`, `chomp`, class/end matches) | 480 | The line split, chomped lines and the enclosing class/module per line do not depend on the name searched for. `CoreMixins.layout` builds them once per source, and `CoreCompare.verified` reuses that layout for all four operators. |
| `indent_lines` (`compile_operator_fallback`, ComputedSend, ArgShapeCalls, block fallback) | ~240 | `text.gsub(/^/, prefix)` replaces `text.lines.map { "#{prefix}#{line}" }.join`. `^` matches at the start and after every newline except a final one, which is where `String#lines` splits. Empty text returns `''`, since `gsub` would return the prefix. |

`codegen_send.rb` has similar sites (`guarded_fallback_line`,
`strict_hint_wrap`) but was left alone because another open change edits it.
`OwnerCallDirect.rewrite` splits the whole program into lines (313 samples) to
rewrite about 550 of them. Avoiding that needs a lazy line view that also keeps
earlier rewrites visible to `guard_chain_classes`, so it is left for a separate change.
`Integer#to_s` (2.4%) is spread over about 190 `r#{reg}` interpolations, with no
single dominant site.

## Equivalence

- Rewritten helpers were compared with the old expressions on 200,000 random
  strings built from whitespace (including NUL, `\v`, `\r\n`), `//`, register
  spellings (`r1`, `r07`, `xr3`, `R2`), UTF-8 and backslashes. The corpus was
  every bc2cpp source and a generated Optcarrot `.cpp`, each whole and in
  7-line chunks. Compared: `transparent?`, `mentions`, `mention_mask`, the
  blank-line test, `token_stem` over all 23,364 identifier tokens of that
  corpus, and `indent_lines` with five prefixes. The results were identical.
  `indent_lines` results also had the same encoding except for empty text,
  where the old `[].join` was US-ASCII.
- Every timed pair below produced the same generated C++. The only bytes that
  differed were the per-run temporary world path, both plain and hex-encoded.
- The `scripts/bc2cpp/*_check.rb` harnesses that reference the touched code
  (52) pass, except three that fail identically on the baseline:
  `class_object_args_check`, plus `exception_init_check` and
  `super_optional_check`, which need a built `mruby/presym/id.h`.

## Measurement

Three alternating unsampled `--optcarrot` runs per version, after one warm-up
each. Ruby 4.0.5, mrbc from pinned mruby, baseline `510bcd4b4`:

| Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 10,839,373 | 10,352,458 | 9.623 | 9.168 |
| 2 | 10,839,339 | 10,352,458 | 9.923 | 9.712 |
| 3 | 10,839,405 | 10,352,344 | 9.884 | 8.881 |

This removes about 487,000 allocations per compilation (4.5%). Other jobs were
running on the machine at the same time, so these runs do **not** establish a
speedup.
