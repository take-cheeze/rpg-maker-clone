# 0216. bc2cpp calls one outlined helper per index op instead of an inline chain

Date: 2026-09-23

## Status

Accepted

## Context

For an untyped `x[i]` (the GETIDX opcode), bc2cpp emitted the same long
chain at every site:

1. an exact-class Array with an Integer key (`bc2cpp_ary_entry`);
2. an exact-class Hash (`mrb_hash_get`);
3. an exact-class String with an Integer, String or Range key
   (`mrb_str_aref`);
4. STRUCT_INDEX_CACHE's branches, one per Struct owner that declares a
   literal Symbol key as a member;
5. INDEX_CHAIN: `compile_poly_small_n('[]', ...)`, an exact-class chain
   over every compiled `#[]` in the program (LCF::Sections, LCF::Array1D,
   LCF::Array2D, LCF::File, Game::Switches, Game::Variables, Game::Actors
   and LRUBitmapCache), ending in the by-name `bc2cpp_send` fallback.

That comes to roughly 500 bytes of `-Os` code per site. There were 1,486 such
sites in the RPG2k gem on master, and the pending `claude/lcf-bracket-access`
branch (ADR 0213) raises that to 2,320 by reading LCF fields as `row[:field]`.
GETIDX0 (`x[0]`) and SETIDX (`x[i] = v`) repeat shorter chains of the same
kind (steps 1 and 2 plus a by-name fallback).

Only step 4 depends on the site: POLY_SMALL_N's candidates are a function of
the name and the arity, not of the call site. ADR 0209 removed the same kind
of per-site repetition for dynamic sends by outlining them into
`bc2cpp_send`.

## Decision

OUTLINED_INDEX_OPS (`tools/bc2cpp/bc2cpp.rb`, next to
`compile_struct_literal_index_read`): each generated file gets up to three
static helpers.

- `bc2cpp_getidx(M, recv, key)` holds steps 1, 2, 3 and 5 in the same order,
  with the same checks and the same fallback. Its POLY_SMALL_N arm calls the
  same `_impl` functions, including another gem's impls through its
  `*_decls.h`, and its `mrb_funcall` goes through SYMBOL_CACHE like every
  other send.
- `bc2cpp_getidx0(M, recv)` holds GETIDX0's Array/Hash/by-name chain.
- `bc2cpp_setidx(M, recv, idx, val)` holds SETIDX's chain. It returns the
  assigned value on the fast paths and the method's result on the fallback,
  as before.

A generic site becomes a single call such as
`r5 = bc2cpp_getidx(M, r5, r6);`. The site-specific parts stay inline:

- STRUCT_INDEX_CACHE's branches for a literal Symbol key are emitted first,
  and the helper is called in the `else` arm. A Struct's type tag can never
  pass the Array, Hash or String checks, so moving them ahead of those
  checks changes nothing.
- The typed and static-receiver paths are unchanged
  (`compile_typed_index_send`/`compile_typed_index_write`, and
  `static_indexable_class`'s Array/Hash paths). Their guard's `else` arm now
  calls the helper.
- A method that installs `[]` at runtime (RUNTIME_DEF_DEVIRT_GUARD) keeps the
  old inline chain, because its chain must skip POLY_SMALL_N. The shared
  helper is built against top-level method state, so one method's guard
  cannot leak into it.

A helper is built the first time a site needs it. Building it at that point
also allocates its OWNER_CLASS_CACHE slots before that table is printed. A
helper is emitted only when the finished code calls it: a helper built for a
method that was later dropped is left out. The stderr summary counts the
sites (`== outlined index ops: getidx N, getidx0 N, setidx N sites ==`).

The helpers' `"[]"` and `"[]="` literals land in the SYMBOL_CACHE table.
`static_dispatch_registrations.rb` therefore still counts them as dynamic
uses of those names, and neither name is an identifier in the first place.
None of the helpers' shapes is a MONO_EMBED_GUARD fallback, so the
EMBED_GUARD_FALLBACK exemption is unaffected.

## Consequences

Sizes are the `.text` of each compiled gem's `register.o`. Each was compiled
from the build's own compile line with `-Os` added (that line carries no
`-O` flag, because CMake hands rake an empty `CXXFLAGS`).

| base | gem | before | after | change |
| --- | --- | ---: | ---: | ---: |
| origin/master `cd955085` | rpg2k | 4,604,188 | 3,871,095 | -733,093 (-15.9%) |
| | lcf | 61,493 | 52,398 | -9,095 (-14.8%) |
| | rgss | 187,229 | 167,508 | -19,721 (-10.5%) |
| `claude/lcf-bracket-access` (`d8fb762c`, `a7873a80` on `cd955085`) | rpg2k | 5,007,045 | 3,913,107 | -1,093,938 (-21.8%) |
| | lcf | 58,962 | 51,100 | -7,862 (-13.3%) |
| | rgss | 187,598 | 167,909 | -19,689 (-10.5%) |

The sites converted in the RPG2k gem are 1,486 GETIDX, 28 GETIDX0 and 370
SETIDX on master, and 2,320, 28 and 370 with `claude/lcf-bracket-access`. The
lcf gem has 18/0/2 and the rgss gem 31/18/14. On the branch, the gem's growth
over master falls from +403 KB (+8.7%) to +42 KB (+1.1%). Before #1908 turned
the RPG2k Structs into classes, the same comparison on `535e0038` gave
4,750,480 -> 3,809,978 (-19.8%) for 1,980 GETIDX sites.

Speed was measured with callgrind on the `--rpg2k_battle_troop=1
--rpg2k_battle_play` scenario, collecting only inside `Scene::Map#drive_battle`.
The battle took 241 frames in every run. Instructions went from 657,278,954
to 657,422,490 (+0.02%). On `535e0038` the same pair measured 654,219,888 ->
654,597,158 (+0.06%), two master runs there differed by 2,327, and the lcf
gem's `bc2cpp_getidx` alone ran 350,615 times in the battle. The extra cost
is the call into the helper.

Marking the helper's POLY_SMALL_N tail `[[gnu::cold, gnu::noinline]]` was
measured and not adopted. It saves 17 to 64 bytes per gem, because the helper
exists once per file. It would also mark a hot path cold: LCF's `#[]`
receivers reach their impls through that tail.

`scripts/bc2cpp_outlined_index_check.rb` covers the codegen: a generic site
calls the helper, a Struct-literal site keeps its branches, and an unused
helper is not emitted. It also runs a fixture on real mruby, first as
bytecode and then compiled, and checks that results, receivers and raised
errors match, with the expected number of by-name dispatches. The checks that
matched the old inline text (struct index, runtime devirt, SETIDX and retclass
devirtualization, nested compile state) now look for the helper call instead.
