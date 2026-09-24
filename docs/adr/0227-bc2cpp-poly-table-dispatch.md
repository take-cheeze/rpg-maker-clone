# 0227. bc2cpp dispatches names past the POLY_SMALL_N cap through a shared table

Date: 2026-09-24

## Status

Accepted

## Context

For a polymorphic send, POLY_SMALL_N (ADR 0160, INHERITED_GUARD in ADR 0207)
emits a chain at every call site: one exact-class `if` per eligible
definition, calling that class's `_impl` directly, and the guarded fallback
(`mrb_funcall`, or `bc2cpp_nomethod` where the closed world proves the else
arm dead) for every other class. `POLY_SMALL_N_MAX` caps the chain at 16
candidates, because the chain is repeated per site and its compares grow
linearly. A name past the cap went to plain dynamic dispatch at every site.

Measured over the real registry: the three compiled gems' own bc2cpp runs
(`ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS` as their `mrbgem.rake` passes
them, full host build), with the cap lifted only for counting, and with the
same filters `poly_small_n_targets` applies. Exactly one name exceeds it:

| name | registry defs | eligible owners | dynamic sites (lcf / rpg2k / rgss) |
| --- | ---: | ---: | --- |
| `update` (0 args) | 22 | 19 | 0 / 15 / 28 |

The 3 excluded definitions are `RGSS::Input.singleton` (a singleton owner
never matches an `mrb_obj_class` guard), `RPG2k3::Scene::Battle` (does not
compile clean) and one native definition. The 19 owners are `Game::Screen`,
`Game::Picture`, `Game::Interpreter`, `RPG2k::Window` and 15
`RPG2k::Scene::*` classes; none has an inheriting subclass. Of the 43
dynamic sites, 10 are in `RGSS.effect_probe`, which installs singleton
methods at runtime (RUNTIME_DEF_DEVIRT_GUARD), and must stay dynamic.

Under HOT_ONLY (ADR 0214: the psp, wio and maix builds), only 4 `update`
definitions are compiled, so the name is already a POLY_SMALL_N chain there
and nothing past the cap exists.

## Decision

POLY_TABLE (`compile_poly_table` in `tools/bc2cpp/codegen_ivar_poly.rb`) is
tried after `compile_poly_small_n` for a POLY send, before plain dynamic
dispatch:

- **Eligibility** is `poly_candidates`, the uncapped body that
  `poly_small_n_targets` now wraps with the cap (same devirt-blocked-name,
  repeated/singleton owner, clean irep, pure mandatory arity, native argument
  and `ONLY_OWNERS`/`OTHER_OWNERS` gates). The tier engages for 17 to
  `POLY_TABLE_MAX` (64) candidates. Accessor candidates have no `_impl` to
  point at, so they are left to the fallback.
- **One table per distinct row list**, shared by every site of the name:
  `{owner class getter, _impl, OWNER_CLASS_CACHE slot}` rows. The candidates
  can differ between sites of one name (the probe runs saw 18 and 19), so a
  table is keyed on its rows, not just the name. INHERITED_GUARD is
  flattened at build time: each inheriting subclass gets its own row with
  its ancestor's `_impl`, so a lookup is one pointer compare per row.
- **The site** is
  `if (fn = bc2cpp_poly_lookup(M, mrb_obj_class(M, recv), table)) r = fn(M, recv, args...); else <fallback>`.
  The fallback is `guarded_fallback_line`, exactly as in a POLY_SMALL_N
  chain, listing the table's classes. It stays per site because the closed
  world's decision depends on the site's `self`.
- **One shared lookup function** per file (not per name, and not a template),
  holding the table's size in its data. The function pointers are stored
  type-erased as `void (*)(void)` and cast back at the site to the
  `mrb_value (*)(mrb_state*, mrb_value...)` shape every candidate shares
  (pure mandatory arity `n`, all `mrb_value`).
- **Lookup order**:
  1. A `Class`/`Module` receiver (`Graphics.update`, `self.update` in a
     module function) returns "none" before scanning.
     POLY_TABLE_NO_CLASS_ROW keeps `Class` and `Module` out of the rows, so
     that shortcut can never skip a match.
  2. An 8-entry memo per table, indexed by the class pointer, remembers
     recent results, misses included.
  3. Otherwise a linear scan compares each row's resolved
     `bc2cpp_owner_class_slots[slot]`. A row calls its getter only while its
     slot is still empty.
- **The memo is sound by construction.** A hit's key is an owner class,
  trusted exactly as its OWNER_CLASS_CACHE slot already is. A stale miss (a
  freed class whose address is reused) can only send that class to the
  fallback, which is always correct. The memo is declared inside
  `emit_owner_class_cache` and cleared by `bc2cpp_reset_owner_classes`, which
  gem_final calls, so a later VM that reuses addresses never reads it.
- **Emission**: OWNER_CLASS_CACHE slots and memo space are taken only for
  the tables the final (post-`SKIP_UNSUPPORTED`) code uses, just before that
  cache is printed. A dropped table takes nothing, and no existing slot is
  renumbered. The tables are printed after the outlined index helpers, ahead
  of the compiled bodies. The stderr summary prints
  `== poly table dispatch: update (bc2cpp_poly_table_2, 19 classes) 18 sites ==`.
- The site marker `// POLY_TABLE :name` is not in
  `RUNTIME_DEF_DYNAMIC_MARKERS`, so `runtime_def_devirt_audit` treats it as
  a static bind, the safe default.

### Why a plain linear scan was not enough

The first version scanned rows by calling each row's OWNER_CLASS_CACHE
getter through its function pointer. A callgrind micro-benchmark (19 classes
with a trivial `update`, one compiled `x.update` loop, 200,000 calls per run,
Ir per call from `Ir(K) - Ir(0)`) measured the cost per call:

| receiver | plain dispatch (master) | getter scan | slot scan | slot scan + memo | + memo, out-of-line lookup (adopted) |
| --- | ---: | ---: | ---: | ---: | ---: |
| first row | 285 | 59 | 53 | 65 | 82 |
| last (19th) row | 285 | 329 | 215 | 65 | 82 |
| module (`Mod.update`) | 285 | 314 | 314 | 317 | 338 |
| class not in the table | 285 | 594 | 482 | 330 | 347 |

At about 15 Ir per row, the getter scan made a last-row hit slower than
mruby's method-cached `mrb_funcall`, and a miss cost double. Reading the
resolved slot directly brings a row down to about 9 Ir. The memo makes every
hit cost the same wherever its row is. With one site, GCC inlined the lookup
into it (the "slot scan + memo" column). The adopted lookup is
`[[gnu::noinline]]`, so a file keeps exactly one copy; the real builds, with
15 to 18 sites, compiled to the same size either way. That costs about 17 Ir
per call: a hit is 82 Ir (-71%), and a miss is 53 to 62 Ir over plain
dispatch (+19% to +22%). Sorting the rows by class pointer for a binary search was not
pursued: pointers exist only at runtime, so it would need a per-VM sorted copy
with the same reset hook as the memo, and it would still cost about
log2(19) compares on every call where the memo costs one.

## Consequences

- On the full build, all 33 remaining `update` sites (rpg2k 15, rgss 18)
  call the compiled `_impl` directly for the 19 listed classes. Every other
  receiver still dispatches normally. Which receivers dominate at runtime is
  workload dependent: scenes, windows, the interpreter and pictures hit the
  table; native RGSS objects (`Sprite#update`) and modules miss it.
- Code for every name at or under the cap is unchanged. Undoing the 33 sites,
  the table and the memo declaration turns the new output of all three gems
  back into origin/master's, byte for byte. The hot-only output and the
  `*_decls.h` headers are byte-identical without any undoing.
- Size: `.text` of each compiled gem's `register.o`, from the host build's
  own compile line (which uses `-O3`), and from the same line with `-Os`.
  Base is origin/master's generated C++ for the same tree:

  | gem | sites | `-Os` base | `-Os` table | change | `-O3` base | `-O3` table | change |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | rpg2k | 15 | 3,938,120 | 3,939,114 | +994 (+0.03%) | 6,993,370 | 7,037,329 | +43,959 (+0.63%) |
  | rgss | 18 | 167,257 | 168,609 | +1,352 (+0.81%) | 289,408 | 293,572 | +4,164 (+1.44%) |
  | lcf | 0 | | | 0 | 87,977 | 87,977 | 0 |

  At `-Os`, a site costs about 55 to 75 bytes over a plain
  `bc2cpp_send`, including the one out-of-line lookup per file. The rows
  (24 bytes each on 64-bit, 12 on 32-bit) and the memo (16 or 8 bytes per
  entry) are data, not `.text`. At `-O3`, rpg2k grows about 2.9 KB per site.
  The lookup is out of line either way, so this is GCC optimising the large
  enclosing functions differently once they have the extra branch. It does
  not affect the flash builds: they are hot-only, so they have no table.
- The table's slot list must stay in step with OWNER_CLASS_CACHE: rows index
  `bc2cpp_owner_class_slots`, so that cache and the tables are emitted by
  the same run and reset together.
- `scripts/bc2cpp_poly_table_check.rb` (bc2cpp CI job) pins the shape on a
  fixture: a 17-definition name gets one shared table (including an
  INHERITED_GUARD subclass row), a 16-definition name stays a POLY_SMALL_N
  chain, and a world with no name past the cap emits nothing of the tier. It
  also runs the fixture on real mruby in two VMs, one after the other, with
  a gem_final-style reset between them. Every call returns the interpreter's
  answer; a table hit makes no dynamic dispatch, and an accessor owner, a
  module or a class defined outside the closed world makes exactly one,
  whether the answer comes from the scan or from the memo.
- Follow-up: measure the per-frame effect with callgrind on a real scene
  trace (as ADR 0216 did). That needs the SDL engine build, which was not
  available where this was written. The tier is worth revisiting if a second
  name crosses the cap, or if `update` loses candidates and drops back under
  it.
