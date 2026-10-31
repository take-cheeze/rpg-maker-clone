# Owner-aware native names in CHA_SELF

The owner proof is on by default; `BC2CPP_OWNER_NATIVE_READ=0` turns it off. It lets CHA_SELF (`cha_self_plan`, `tools/bc2cpp/codegen_ivar_poly.rb`) prove a
`self`-send's name when the name has outside definers, provided none of them sits on the receiver's lookup path.
On by default. With `BC2CPP_OWNER_NATIVE_READ=0` the output is the one the name-level gate gives.

## Why

CHA_SELF enumerates every class an instance of `self`'s class can be (the class and its descendants). For each one it
needs the lookup of the name to land on a known Ruby definition. `inherited_lookup_safe?` answers that by name: a
name that any outside source defines is refused for every class. The census (`scripts/bc2cpp/self_send_census.rb`)
shows the effect on the engine: `read` is defined natively on IO, StringIO and Dir, so the 243 `read` self-sends of
`LCF::SaveTyped::Record` fell to the POLY chain and its owner-table else. A native `read` on IO is not on the lookup
path of any `LCF::SaveTyped` record, so the name-level refusal is more than the proof needs.

## The fact and the chain check

- **Owner-aware definers.** `outside_owner_call_owners(name)` (`codegen_outside_owner_call.rb`) lists the classes that
  answer `name` among outside definers: native registrations by owner (`NativeOwnerMap`), computed-name owners, outside
  and core Ruby definitions. It is nil whenever a definer cannot be named (an unknown owner, a native prepend, an
  outside method_missing), so an uncovered name keeps the name-level refusal.
- **Lookup path.** `owner_native_lookup_path` walks, from `self`'s class and every descendant, the superclass chain and
  the included and prepended modules, then Object's core tail (`CoreHierarchySigs.ancestors('Object')`). It is nil when
  any class is not resolved (`ClosedWorld#class_parent`), a mixin is unknown, a module is not declared, or a native
  include lands on the path with a module the path does not list.
- **Gate.** The proof holds when no definer is on that path, no descendant is wild (its superclass unresolved), and
  `name` has no unknown installer. `cha_self_plan` then skips only the name-level refusal and the `<native>` placeholder
  refusal (`:native_definition`); both exist to stand in for an owner the closed world cannot name. The rest of the plan
  (installed names, method_missing, the default lookup target, overriders, mixins of descendants) runs unchanged.

## Soundness

A direct call to the default target is sound when every receiver CHA_SELF enumerates resolves `name` to it. For an
instance of `self_owner` or a descendant (an instance method's `self` is an instance of its owner, `self_class`):

1. The lookup from each such class walks its path. A native definer of `name` on the path would answer first, so none
   may be on it (checked against `outside_owner_call_owners`).
2. A mixin or prepend on the path that defines `name` is refused by the existing plan (`cha_mixin_may_define?`,
   `cha_module_may_define?`), and the path walk refuses any mixin it cannot name.
3. Ruby definitions in the descendants are the overriders the plan already places (exact-class arms); with none, the
   plan emits the direct call with no else arm (`cha_self_code`), which is CHA_SELF's existing closed-world claim.
4. A native definer above the default owner (on Object or Kernel) is also refused: the path includes the core tail.
   This is conservative; the default owner shadows it.

Core forwarders that install a computed name are trusted as `NativeOwnerMap` and `outside_owner_call_owners` trust them
in the default mode (`BC2CPP_NATIVE_OWNER_MAP=trusted`); `BC2CPP_NATIVE_OWNER_MAP=0` turns the owner list off, and the
gate then refuses everything the name-level gate refused.

## Checks

- `scripts/bc2cpp/owner_native_chain_check.rb` (needs `MRBC`): a record class with 18 descendants and an overrider gets
  a direct `read` with no owner call, with the flag on, and keeps its owner call with the flag off. A descendant that
  mixes in a module defining `read`, and a class under StringIO, keep their by-name self-send with the flag on. Against
  the pre-change `bc2cpp.rb` (`BC2CPP_TOOL=`) the positive cases fail.

## Measured (census, `scripts/bc2cpp/self_send_census.rb`)

| | flag off | flag on |
| --- | ---: | ---: |
| `direct` | 4,635 | 4,879 |
| `owner_table` | 293 | 49 |
| `class_body` / `not_recorded` | 223 / 36 | 223 / 36 |

244 self-sends change from `owner_table` to a direct call: 243 `read` on `LCF::SaveTyped` records (each to
`LCF::SaveTyped::Record#read`, with no overrider in the closed world) and 1 `path` attr_reader in `save_typed.rb:132`
(its outside definers are on `File` and `RGSS::Bitmap::LoadError`, neither on the record's path). Two
`visible=` sends in `mruby-rpg2k/mrblib/main.rb` were already direct and now carry the CHA_SELF label; their emitted
line is unchanged. With the flag off every census row matches master's.

Closed builds (`scripts/bc2cpp/closed_build.bash`, both exit 0): the generated `read` owner calls go from 257 (flag off)
to 14 (flag on). The 14 left are `read` sends on class-object receivers (`LCF::SaveTyped.read`), not record self-sends.
The flag-off closed-world bc2cpp pass (the census's compile, without the hook) is byte-identical to master's: 472,383
lines, after normalizing the root path. No master closed build was made, so the build's `_gen.cpp` files were not
compared with master's.

## Not covered

- Names whose owners the owner list cannot name: `outside_owner_call_owners` is nil for them, and they keep the
  name-level refusal.
- Sends that do not reach CHA_SELF (class bodies, literal blocks), and the other owner-table reasons in the census
  (`OUTSIDE_OWNER_CALL`, `ARRAY_PUSH`, alias and candidate-set refusals).
