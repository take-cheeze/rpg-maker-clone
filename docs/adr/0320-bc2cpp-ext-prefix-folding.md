# 0320. bc2cpp: EXT1/EXT2/EXT3 are folded into the instruction they widen (EXT_PREFIX)

Date: 2026-10-02

## Status

Accepted

## Context

mruby widens the operands of one instruction with a prefix opcode (`EXT1` the first operand, `EXT2` the second, `EXT3`
both; `ops.h` `FETCH_*_1/_2/_3`). `InsnDecoder` already read the widened operand values, but it still emitted the prefix
as an `Insn` of its own, in front of the instruction it widens. Every pass that walks the instruction list therefore met
an op it has no model for, and the passes are whitelists: an unknown op ends the walk and the iseq (or the fact) is
refused, because an unmodelled op may write any register. ADR 0308 measured the cost and left it unbuilt: "154 of 225
constant pools dropped because their class body has an `EXT2`".

### Phase 1: measurement

Wio closed world, master `cd86085f`, `scripts/bc2cpp_coverage_report.rb` shipped pass (`SKIP_UNSUPPORTED=1`).

| What carries a prefix | Count |
| --- | ---: |
| ireps with a prefix (of 3,613) | 3 |
| prefixes: `EXT2` / `EXT1` / `EXT3` | 635 / 9 / 0 |
| the 3 ireps | class bodies of `LCF::Schema` (261 registers), `RPG2k::Interpreter`, `RPG2k::Scene::Map` |
| what `EXT2` widens (top) | `METHOD` 160, `DEF` 160, `TDEF` 114, `SETCONST` 87, `LOADSYM` 49, `GETCONST` 37, `GETMCNST` 25 |

No method of the engine carries a prefix, so none was dropped for one: the prefix cost is in class bodies, which the
analyses read (constants, ivars, frozen tables), not in compiled methods. A method with more than 255 registers is
dropped today because `compile_insn` answers `#error unhandled opcode EXT1`.

The sites that refuse, all by an op whitelist the prefix is not on:

| Site | Refuses | What it feeds |
| --- | --- | --- |
| `NumericFlow.states`, `SUPPORTED_OPS` (`numeric_flow.rb`) | the whole irep | class pools (ivar, argument, constant), frozen tables, numeric operand facts, captured locals |
| `CallFacts#states` (`call_facts.rb`) | the whole irep | call-site receiver facts |
| `FIXNUM_PROOF_STEP_OVER_OPS`, `BytecodeIR::WRITES_LEADING_REG_OPS` | the backward walk | numeric operand proof, reaching definitions |
| `DefineMethodSites.site` | the site (a prefixed `define_method` body is "conservatively left alone") | `define_method` installers |
| `zsuper_forward_plan`, the `ARGARY`/`SUPER` pair | the site ("an interposed EXT declines") | zsuper forwarding |
| `compile_insn` default arm | the method (`#error`, then dropped) | any method with a register past 255 |

`EscapeAnalysis` (its `PASSES` set) and `preceding_name_args` already stepped over a prefix; `Registry` and `CoreDefs` use
`previous_real_index`.

Per analysis, the only ones that move on the engine are those that read the three class bodies: constant pools,
argument pools and the numeric facts that read them. Ivar pools (187), frozen tables (49 shapes), `bc2cpp_nomethod`
(4,380) and the compiled methods do not move: nothing they read carries a prefix.

## Decision

`InsnDecoder::Decoder#run` returns **one** `Insn` for `EXTn + insn`:

* operands widened as before (`operand_sizes`);
* `addr` is the prefix byte. A branch target or a catch handler's `begin_addr`/`end_addr`/`target` names the first byte
  of the whole encoding (mrbc records the pc before it emits the prefix), so `BytecodeIR`'s address map, the `L<addr>:`
  labels and the handler ranges need no change;
* branch targets are `next_pc + offset` with `next_pc` after the widened operands, which is where the VM measures them;
* `lineno` is the line of the widened opcode, as in the unfolded listing;
* a prefix at the end of the iseq, or followed by another prefix, raises (no silent resynchronisation).

No analysis refuses an iseq for a prefix any more. The whitelists, `EXT_OPS` and `previous_real_index` stay because
`BC2CPP_EXT_PREFIX=0` gives the old listing, and they are the only code the kill switch needs; the `#error` arm of
`compile_insn` is unchanged (it can no longer see a prefix). Registers past 255 reach the C++ as `r256`...: the entry
declares one local per register of `nregs` and every use is `r<N>`, so no register array or width needed a change
(run against the interpreter on full-core, core-only and 32-bit `mrb_int` builds).

Kill switch `BC2CPP_EXT_PREFIX=0`: `shipped.cxx` byte-identical to master (`cmp`).

### Results

Same tree, switch off against on (`shipped.cxx`, wio closed world):

| | off | on |
| --- | ---: | ---: |
| constant pools | 658 | 796 (+138) |
| argument pools / entry-argument numeric facts | 110 / 106 | 115 / 111 |
| numeric constant facts | 668 | 806 |
| ivar pools / frozen table shapes | 187 / 49 | 187 / 49 |
| `INDEX_EXACT` arms | 977 | 1,000 (+23) |
| arms whose send `NUMERIC_OPERAND_PROOF` removed | 423 | 427 (+4) |
| `bc2cpp_send` in generated bodies / with guarded fallbacks | 2,603 / 3,028 | 2,582 / 3,006 (-21 / -22) |
| `bc2cpp_nomethod` sites | 4,380 | 4,380 |
| `shipped.cxx` lines | 443,754 | 443,630 |

This is removal, not relocation: no site moved to another by-name path (untyped `GETIDX` sites behind the class gate fall 2,069 -> 2,064; the
`slow_*` arm counts fall by the removed arms). The yield is small, as ADR 0308 predicted for the by-name sites: the +138
constant pools are almost all constants of those three class bodies that no method reads through an exact-class send.

## Consequences

* A method with more than 255 registers now compiles instead of being dropped. None exists in the engine today.
* The checks that read the listing text (`bc2cpp_binary_loader_check.rb`) fold the `mrbc -v` prefix lines the same way.
* `scripts/bc2cpp_ext_prefix_check.rb` and its mutation check (eight mutants and a control, mutated inside the repository)
  guard the folding; the shard `ext-prefix` runs them.
* Not built: nothing else is gated on a prefix. Next-best levers (ADR 0308 table): exact arm for `ARRAY_PUSH`, the
  `attr_writer` call-site join, constructor argument pools.
