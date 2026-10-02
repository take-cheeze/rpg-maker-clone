# 0312. bc2cpp: element classes of mutable containers, measured and not built

Date: 2026-10-02

## Status

Accepted (a decision not to build; revisit if a trigger below fires)

## Context

ADR 0296 left element classes unbuilt (an Array or Hash is mutable and aliasable, so a slot's class is the join of
every store through every alias). ADR 0306 (open, PR #1977) built the one slice with no alias problem, `[..].freeze`
literals, and measured it at -6 sites. ADR 0285 types a record Hash held in an ivar when every use is a literal-key
read or write; ADR 0294 types LCF rows by schema. This ADR asks what is left: elements of **mutable** Arrays/Hashes
(ivars, locals, parameters) read by `GETIDX`, `first`/`last`/`max`/`min`, `each` elements, and whether a conservative
all-writers-known, non-escaping analysis could give them an exact class, so the receiver becomes a direct call.

The ADR 0308 branch (`claude/rpg2k-container-receivers-m6k`, captured-local class flow, WIP) was fetched and read: it
types a *variable* by the assignments to its register and says it needs no points-to information, so it adds no
container identity either. There is no per-container kind, alias scan for Arrays or non-Symbol-keyed Hashes to build on;
ADR 0285's `RecordHash` scanner is Hash-with-Symbol-keys only.

## Method

Wio closed world, master `247a34e4`, shipped pass of `scripts/bc2cpp_coverage_report.rb` (all three compiled gems),
restricted to the engine owners (`RPG2k*`, `Game*`). Two measurements, both reproducible:

- `scripts/bc2cpp_dynamic_site_census.rb` (ADR 0295/0296 style), looking at the `indexed_result` receiver origin.
- New `BC2CPP_ELEMENT_REPORT=<tsv>` (`tools/bc2cpp/element_site_report.rb`) plus `scripts/bc2cpp_element_site_report.rb`:
  every instruction whose emitted code can still reach a by-name call, the origin of its receiver or operand through
  reaching definitions (an element read shows its container's origin inside), and, for container ivars, the class set
  of every `@x = <literal>` and every `[]=`/`<<`/`push` into them. A class set is the meet of the exact-class flow
  (ADR 0289/0296) and the numeric flow; `OTHER` means no flow names it. The report only reads: generated `shipped.cxx` and
  the coverage report are byte-identical with it on.

"Sites" below are instructions that **can reach** by-name dispatch (they include the else arm of a guarded fast path),
so each number is an upper bound on what a proof could shed, and a count of instructions, not of `bc2cpp_send` lines.

## Results

**The `indexed_result` receivers are mostly not mutable containers.** The census has 95 engine sites with that origin
(of 2,205 engine dispatch sites). 49 are `to_s`, 12 `empty?`, 7 `length`, 5 `cover?`; the key is an LCF field name
(`name`, `description`, `type`, `file`, `background_name`) or a key of the engine's own battle record Hash
(`target`, `attacker`, `actor`). Those are `row[:name].to_s` on a row the LCF flow could not reach (a parameter, a
method with a `rescue`, ADR 0294's blockers) and `@ui[:key]` values: row typing and call-result typing, not element
classes of a mutable container.

**All element reads, by what the container is** (15,349 engine sites reach by-name dispatch; 1,151 read an element):

| container | sites |
| --- | ---: |
| ivar | 380 |
| parameter / block parameter | 231 |
| element of an element (`db[:a][i][:b]`) | 151 |
| implicit-self call result (`items[i]`) | 112 |
| call result | 106 |
| captured local | 72 |
| fresh literal | 48 |
| analysis refused (handler, query budget) | 44 |
| constant / other | 36 |

Only the ivar row is the slice asked for; the others are receiver-class problems of other ADRs (parameters 0294/0295,
call results and captured locals 0289/0308, nested elements 0294).

**Container ivars (36 ivars, 380 reads).** `@ui` 145 (the Battle record Hash, ADR 0285), `@list` 45, `@db` 38 (LCF),
`@name_ui` 20, `@vehicle_chars` 12, `@number_input` 10, `@timers` 10, `@queue` 9, `@base_raw` 8, then a tail of 27 ivars
with at most 7 each. An element has a known class only if *every* value stored through *every* alias has one:

- 74 creations (`@x = ...`) were seen; 22 store a literal whose contents have known classes (or nothing). The rest
  store a parameter, a method result (`@base_raw = curve.dup`, `@queue = turn_order`) or a block result.
- 192 element writes (`[]=`, `<<`, `push` into one of these ivars) were seen; 84 store a value whose class set is known,
  108 store `OTHER` (a method result or argument; `@ui` alone: 76 of 126).
- **5 of 36 ivars have a creation and every creation and write classed**: `@timers` (10 reads), `@vehicles` (6),
  `@timer_sprites` (5), `@inn_window` (4, already an accepted ADR 0285 record slot) and `@pictures` (3). That is **28
  reads, 0.18% of the 15,349 sites**, and it is a ceiling: aliasing, escapes, `each` block parameters, `Marshal` and
  reflection are not even checked yet.

**`[a, b].max` / `.min`.** 77 sends, 70 on a literal built by the previous instruction (so nothing else can hold it).
Element class sets: `[OTHER, INT]` 42, `[OTHER, OTHER]` 14, `[INT, OTHER]` 6, `[INT|OTHER, INT]` 3, `[INT|OTHER, OTHER]` 2,
`[OTHER, FLT]` 2, **`[INT, INT]` 1**. The CORE_MIN_MAX inline already handles Integer and Float elements; its by-name
send is the fallback for any other element, and it can only go when every element is a proven Integer (a Float may
be NaN): 1 site. The unknown element is `value / 2`, `x - y` of a parameter, an attribute read: the same value-class
problem, in a temporary.

No `Array.new(n, 0)` / `Array.new(n) { Integer }` container ivar exists to prove: a one-off writer-kind census of the
36 (not kept in the report) found `X.new` creations only for `@db`, `@map_tree` and `@roster`, none an Array or Hash;
`@base_raw` is `curve.dup` or a block result.

## Decision

Build nothing. The analysis would be sound if written conservatively, but it is not worth building:

1. **The blocker is the value side, not aliasing.** Even granting a perfect alias and escape analysis, only 5 of 36
   container ivars have fully classed contents (28 reads). The elements are method results and parameters; their
   classes are the return-class table's and the argument pools' job (ADR 0289, 0295). A container proof sits on top
   of them and shrinks to whatever they cover.
2. **The machinery does not exist.** A per-ivar container kind (as ADR 0306 does per frozen literal), an alias/escape
   scan for Arrays and non-Symbol-keyed Hashes (the engine's containers are put into Hash literals and passed to sends;
   ADR 0285's scanner refuses 53 of 57 Hash slots for escapes and non-literal stores), a store model for `<<`/`push`/`insert`/`concat`/`fill`/
   `replace`/block mutation, and per-ivar withdrawal rules (`instance_variable_set`, `attr_writer`, singleton makers,
   `Marshal`) would be about the size of ADR 0285 for a ceiling below the 100-site bar ADR 0295 set.
3. **A proof that does not fire is worse than none**: each withdrawal rule is a place to be wrong in an unchecked
   direct call (ADR 0210, 0296's residual risk), and none of them would be exercised by 28 sites.

Not done, and not claimed: the generated code is unchanged (byte-identical `shipped.cxx` and coverage report with and
without the report), so there is no before/after delta, no removal and no relocation. No negative worlds, mutants or
32-bit runs exist because there is no analysis to attack.

## Triggers to revisit

Run the report again (`BC2CPP_ELEMENT_REPORT=elements.tsv MRBC=<host mrbc> ruby scripts/bc2cpp_coverage_report.rb >
/dev/null`, then `ruby scripts/bc2cpp_element_site_report.rb elements.tsv`).

- "Element-read sites on those ivars" (the ceiling line) passes about 100, which needs the value classes first: the
  return-class table (open call-result work) covering method results, or argument pools covering `@ui[:k] = param`.
- A per-container kind lands for another reason (a typed `each`/`map` result, ADR 0306's table kinds extended to a
  non-frozen literal); the element pool would then be the same fixpoint with one more join.
- A closed-world game (not the engine) fills a container ivar from literals only, where this population is large.

## Consequences

`BC2CPP_ELEMENT_REPORT` and `scripts/bc2cpp_element_site_report.rb` are kept as the census, like ADR 0296's guard
hint report; they are loaded only when the variable is set. They are not a CI check: a full run is a whole-program
build, and the output is a measurement with no pass or fail. Nothing in the compiler's output depends on them.
