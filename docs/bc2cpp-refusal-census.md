# bc2cpp refusal census

`scripts/bc2cpp/refusal_census.rb` counts how often the bytecode-IR value query
(`BytecodeIR::Types#at`, see [IR value types](bc2cpp-ir-types.md)) returns an
answer and, when it refuses, why. It ranks the refusal causes so that work on
the analysis can start from measured counts. It generates no code and changes no
output.

## Running it

```sh
MRBC=path/to/mrbc ruby scripts/bc2cpp/refusal_census.rb [--tsv FILE] [FILE.rb ...]
```

With no files it uses every `mrblib/**/*.rb` of `mruby-rpg2k`, `mruby-lcf` and
`mruby-rgss`. Each file is compiled by `mrbc` on its own (`compile_ireps`), so
the census sees the same bytecode the closed world does. `--tsv` writes one row
per query: file, irep label, instruction index, opcode, register, answered flag
and refusal cause.

## Method

- **Query universe.** Every instruction whose opcode is in
  `BytecodeIR::Ops::LEAD_READ_ONLY` (`JMPIF`, `JMPNOT`, `JMPNIL`, `RAISEIF`,
  `MATCHERR`, `SETUPVAR`, `RETURN`, `RETURN_BLK`, `BREAK`) asks for the value
  class of its leading register at that instruction. Plain reads by other
  opcodes (`MOVE` sources, `SEND` receivers and arguments) are not yet counted.
- **Answer.** A query is answered when `Types#at` returns a class set.
- **Cause.** A refused query reports the first refusal cause the dataflow
  recorded. A cause of the form `unknown:<OP>` names the opcode of the reaching
  producer that the query does not model. Other causes are dataflow reasons
  (`query_guarded`, `entry_value`, `opaque_reg`, `state_cap`, `no_predecessor`).
  The census records only the first cause, so a query with several unknown
  producers is counted once, under the first one found.

## Result (closed-world mrblib, 36 files, 2026-10-24)

| Measure | Count |
| --- | ---: |
| Queries | 12,601 |
| Answered | 758 (6%) |
| Refused | 11,843 (94%) |

Refusals by first cause (top entries):

| Cause | Count | Reading |
| --- | ---: | --- |
| `unknown:SEND` | 2,575 | call results |
| `unknown:SEND0` | 1,408 | call results (no-argument send) |
| `unknown:GETIDX` | 1,349 | index reads (`a[i]`) |
| `unknown:SSEND` | 1,319 | call results (self-receiver send) |
| `unknown:GETIV` | 812 | instance-variable reads |
| `query_guarded` | 736 | a guard on the path makes the query refuse |
| `unknown:EQ` | 542 | comparison results |
| `unknown:SSEND0` | 471 | call results (self-receiver, no-argument send) |
| `entry_value` | 407 | a parameter or entry value |
| `unknown:ENTER` | 264 | entry-frame producers |
| `unknown:GT` / `LT` | 236 / 236 | comparison results |

Refusals by the opcode that consumes the value: `JMPNOT` 5,290, `RETURN` 3,502,
`JMPIF` 2,438, `JMPNIL` 197, `RETURN_BLK` 164, `RAISEIF` 158, `SETUPVAR` 94.

The largest consumer-producer pairs:

| Consumer <- first cause | Count |
| --- | ---: |
| `JMPNOT` <- `unknown:SEND` | 1,631 |
| `RETURN` <- `unknown:SSEND` | 975 |
| `JMPNOT` <- `unknown:SEND0` | 664 |
| `JMPNOT` <- `unknown:GETIDX` | 565 |
| `JMPIF` <- `unknown:GETIDX` | 534 |
| `RETURN` <- `unknown:SEND` | 490 |

## What this says

- Most refusals are unmodelled producers, not dataflow limits. Call results,
  index and ivar reads, and comparisons together account for roughly three
  quarters of the refused queries. Those values are unknown by design today
  (see the first layer's note in [IR value types](bc2cpp-ir-types.md)).
- Branch conditions dominate the consumers. A `JMPNOT` on a call result is the
  largest single pattern (1,631 queries), so branch narrowing on nil and class
  tests is a candidate for the next step. Narrowing removes classes from a set
  the query already knows; on an unknown value it cannot produce an answer by
  itself, so call-result modelling is the larger lever.
- `query_guarded` and `entry_value` are the dataflow-side causes. They are worth
  a separate look once the producer causes are addressed.

## Limits

- The census counts queries for leading-register reads only. Codegen asks more
  questions than these, so the shares describe the branch and return consumers,
  not every value the compiler uses.
- Each refused query counts once under its first cause. The census does not
  tell which cause would become the next blocker after a fix.
- The corpus is the three closed-world gems, not the full game. Other programs
  may refuse for other reasons.
- The census uses the real `Types` query path, so it reports the answers the
  compiler gets, not an approximation of them.
