# Receiver-trace and bytecode-loader allocations

Two mechanical allocation sources in the bc2cpp compiler, following
[receiver-trace walk allocations](bc2cpp-trace-walk-allocations.md) and
[IR query allocations](bc2cpp-ir-query-allocations.md).

## Receiver trace

`trace_new_target`, `trace_new_target_reaching` and `trace_new_target_walk`
recurse once per receiver question.

- **Explicit trace options.** `trace_new_target` and
  `trace_new_target_reaching` take the walk's positional and keyword options
  by name instead of `*rest, **opts`. Forwarding a splat cost an Array and two
  Hashes per call.
- **Packed in-progress key.** `TraceReaching::IN_PROGRESS` is a Set per irep
  label holding `TraceReaching.key(idx, reg, resolving_new)`, one Integer,
  instead of a 4-element key Array. Register numbers are 16-bit, so the packing
  is injective, and the key raises on any other register.
- **Unanimity without Arrays.** The reaching definitions are checked for a
  single class in one pass, not with `map` and `uniq`. Every definition is still
  traced, in order, so the memo tables fill as before.
- **Shared lexical candidates.** `LexicalScopes` (`tools/bc2cpp/lexical_scopes.rb`)
  memoizes an owner's enclosing prefixes (`A::B` -> `A::B`, `A`) and the
  frozen `prefix::name` strings. The walk's constant arms,
  `lexically_resolve_construct_target` and `resolve_owner_name` use it
  instead of `sub`/`split`/`join` on every step.
- **No context Hash.** The walk calls `resolve_owner_name_in(name, owner, known)`
  directly. `resolve_owner_name(name, ctx)` remains a wrapper for the other
  callers.
- A bare `GETCONST` uses `const_name` as the written path instead of joining a
  one-element Array.

## Bytecode loading

- **`RiteBinary::Reader`** unpacks fixed-width fields with `unpack1(offset:)`
  and skips without slicing. Only `take` (names, iseq, line maps) still slices.
- **`OperandSchema.parse`** memoizes per `(op, text)`. Synthetic instructions
  repeat a few operand texts (for example, `R2 :* n=1`): about 6,000 parses
  over 1,134 distinct texts. The cached operands, and their values, are frozen,
  as the decoder's shared register operands already are.
- **Decoder operands.** `sym_op`, `name_op`, jump addresses and SEND/SUPER
  `argc` operands come from frozen per-value caches.
- **`instruction_predecessors`** keeps one predecessor as a scalar while it
  builds the lists. A single-predecessor list is a shared frozen
  `SINGLE_PREDECESSOR` Array, and an empty one is `EMPTY_INDICES`. Order and
  deduplication match the old `uniq!`: first-seen order.
- **`indices_with_op`** merges the per-op lists without `uniq` or `filter_map`
  intermediates. Repeated ops are skipped. A single present list is returned
  as is, and several are copied once and sorted.

## Evidence

Sealed Optcarrot compile (`scripts/bc2cpp/compiler_profile.rb --optcarrot`),
Ruby 4.0.5 +YJIT. Each version was run once to warm up its parse cache. Then
three alternating unsampled runs followed (`--mode none`), base = `origin/master`:

| Run | Base `allocated_objects` | Base `elapsed_seconds` | New `allocated_objects` | New `elapsed_seconds` |
| --- | ---: | ---: | ---: | ---: |
| 1 | 6,755,318 | 9.266 | 6,357,902 | 9.707 |
| 2 | 6,755,232 | 8.995 | 6,357,915 | 9.008 |
| 3 | 6,755,267 | 9.766 | 6,357,925 | 9.262 |

That is about 397,350 fewer allocated objects per compile (5.9%). Elapsed time
stayed within run-to-run noise, so this page makes no speed claim.

The object-mode stackprof (interval 100) shows these changes in total samples:

| Frame | Before | After |
| --- | ---: | ---: |
| `trace_new_target` | 1,926 | below 1 |
| `trace_new_target_reaching` | 1,111 | 469 |
| `trace_new_target_walk` | 1,312 | 558 |
| `OperandSchema.parse` | 1,511 | 319 |
| `RiteBinary::Reader#take` | 426 | 89 |
| `instruction_predecessors` | 399 | 50 |
| `indices_with_op` | 732 | 304 |

Before, `trace_new_target_reaching` allocated 366 samples itself; after, it
allocates none. The rest of its total comes from the walks it calls.

Apart from the per-run temporary-world path (`bc2cpp-compiler-profile-...`,
including its hex-encoded string-pool copies), the generated C++ is identical.
[Compiler data profiling](bc2cpp-compiler-data-profile.md) describes the
profiling procedure.
