# 0339. bc2cpp: rewriting the closed world's computed sends as `case` arms, measured worse and not shipped

Date: 2026-10-04

## Status

Accepted (a decision not to ship; revisit if a trigger below fires)

## Context

`scripts/rpg2k_closed_world_lint.rb` (`Dynamic/Send`) had exactly 8 baselined
offences left in the closed world after the earlier passes, all of them
`send` with a computed name in the engine gems (5 in
`mruby-rpg2k/mrblib/game/battle.rb`, 1 in `game.rb`, 2 in
`scene/equip_menu.rb`):

| Site | Sends | Name register |
| --- | ---: | --- |
| `Game::Battle.singleton#flag_of` | 1 | a method parameter, 7 predicate literals passed |
| `Game::Battle#apply_stat_mods` | 3 | `STAT_MOD_FIELD[key]` (a frozen constant Hash) |
| `Game::Battle#apply_knockout_reset` | 1 | `"#{field}="` over a `%i[]` literal |
| `Game::Party#modified_stat` | 1 | a method parameter, `:atk_mod`/`:def_mod`/`:spi_mod`/`:agi_mod` |
| `EquipMenu#draw_stat_row` | 2 | two table columns of `STAT_DEFS` |

Every one of the 8 has a *provably closed* name set, which is exactly the
shape ADR 0303 (`COMPUTED_SEND_EXPANSION`) expands into direct calls. ADR 0303
records these 8 in its Consequences as outside its proof and names the reason:
they build their names from a *parameter* or from a `%i[]` literal that
`SymbolTables` does not admit, not from a frozen constant table, and
`ComputedSend` expands `__send__` only -- never `send`, because `send` comes
from `mruby-metaprog` and a direct arm could then answer where the interpreter
raises `NoMethodError`.

The obvious reading is that the Ruby is what is wrong here, not the tool: if
the closed-world source stops calling `send` and spells the dispatch as a
`case`/`when` over its own literals, the 8 offences go to zero, 6 more entries
come out of the `wio_unreachable_methods` `REVIEWED` table, and the lint
baseline halves from 16 entries to 8. That was implemented in full and
measured with the real code generator, and it makes the generated C++ **worse**.

## Method

`tools/bc2cpp/bc2cpp.rb` over the three edited files
(`mruby-rpg2k/mrblib/game/battle.rb`, `game.rb`, `scene/equip_menu.rb`), host
`mrbc` from `3rd/mruby/build/host/bin/mrbc`, once on the tree with the rewrite
and once with it reverted (`git stash`), same tree otherwise. Dispatch counted
with `scripts/bc2cpp_dynamic_site_census.rb`, the project's own census of
by-name dispatch left in the generated C++, plus a per-`_impl` function count
parsed from the same output. The measure is `bc2cpp_send` call sites in
generated-method bodies: a literal-Symbol `send` and a by-name one are the same
line of C++ either way, so that is the only honest count of "how much work is
left for the runtime to do by name".

## Results

Whole world, three files: **4,412 -> 4,482 `bc2cpp_send` sites, +70.** Only nine
functions changed:

| Function | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `Game::Battle.singleton#flag_of` | 2 | 35 | **+33** |
| `Game::Battle#apply_one_stat_mod` (new) | 0 | 16 | +16 |
| `EquipMenu#party_stat` (new) | 0 | 12 | +12 |
| `Game::Party#modified_stat` | 3 | 13 | +10 |
| `EquipMenu#actor_stat` (new) | 0 | 8 | +8 |
| `Game::Battle#apply_stat_mod_pair` (new) | 0 | 5 | +5 |
| `EquipMenu#draw_stat_row` | 22 | 19 | -3 |
| `Game::Battle#apply_knockout_reset` | 11 | 9 | -2 |
| `Game::Battle#apply_stat_mods` | 12 | 3 | -9 |

The three `send`-bearing functions lose 14 sites and the four helper functions
add 41. `flag_of` is the clearest case: its 2 by-name lines became 35, because
each of the 7 `case` arms compiles to its own `:===` test on the Symbol, a
`respond_to?`, the predicate, and a `!` on its result.

The root cause is visible in the generated `flag_of`:

```c
  r5 = mrb_symbol_value(bc2cpp_sym(M, 293));
  // POLY :=== -- real dynamic dispatch, receiver\'s runtime class decides
  r5 = bc2cpp_send(M, r5, 325, 1, r6);   // :=== on the Symbol
  if (!mrb_test(r5)) goto L50;
  r5 = r1;
  // POLY :respond_to? -- real dynamic dispatch
  r5 = bc2cpp_send(M, r5, 224, 1, r6);
  if (!mrb_test(r5)) goto L41;
  r5 = r1;
  // MONO_EMBED_GUARD :dual_attack? -> Game::Actor#dual_attack?
  if (bc2cpp_owner_class_2(M) == mrb_obj_class(M, r5)) {
    r5 = Game__Actor_dual_attack$3f_impl(M, r5);   // the only direct call
  } else {
    r5 = bc2cpp_send(M, r5, 326, 0);
  }
```

Each arm pays a by-name `:===` on the Symbol, a by-name `respond_to?`, and a
by-name `!` on the predicate result -- three by-name sends to replace the one
`send` the old body made. The one direct call in the middle is the
`MONO_EMBED_GUARD` arm, which the old body got for free *inside* the single
`send` it kept.

This is ADR 0331's finding reached from the other end. There, proving a
*receiver* class would have freed 197-220 of 1,783 by-name sends; the blocker
was that most receivers are parameters, ivars open to natives, or native
results. Here the receivers `b`, `target` and `a` are exactly those: a
parameter, a parameter and a parameter. The `respond_to?` guards the old code
wrote are the source's own acknowledgement that the receiver class is not
known, and `respond_to?` on an unresolved receiver is itself by-name dispatch.
**Removing a computed `send` does not remove the dynamic dispatch; it only
changes which name is computed.** Trading one by-name send for three is a
regression, not a devirtualization.

`apply_knockout_reset` is the one shape that genuinely wins, and it wins for a
different reason than the rewrite: dropping `respond_to?` on names every
`Combatant` answers as an `attr_accessor` removes 4 `respond_to?` sends that
were never dynamic to begin with (11 -> 9 sites, `respond_to?` count 4 -> 0).
That is available without a `case` at all, but it is a `respond_to?` cleanup,
not a `send` removal, and it was not taken here because it does not shrink the
`Dynamic/Send` baseline entries, which stay honest either way.

## Decision

**Not shipped.** The rewrite is reverted; the closed-world lint baseline stays
at 16 entries and `Dynamic/Send` stays at 8. The lint's 8 remaining
`Dynamic/Send` entries are the *honest* statement that these 8 sites carry a
by-name dispatch, and ADR 0303 already documents them as outside its proof. A
baseline entry that says "this site dispatches by name" is more useful to the
next reader than a `case` that dispatches by name three times.

Nothing in the tool changes either: ADR 0303's refusal to expand `send` (only
`__send__`) stands, and this ADR adds the measurement that a source-side
rewrite cannot substitute for it.

## Consequences

* No generated code changes; no kill switch, no removed-versus-relocated number
  beyond the +70 above. `Dynamic/Send` remains 8, the lint baseline 16.
* The 8 sites' name sets were audited as genuinely closed: `flag_of`'s 7
  predicates and `modified_stat`'s 4 modifiers are all passed as literals, and
  `STAT_MOD_FIELD`/`STAT_DEFS` are frozen literals. So nothing about the *Ruby*
  needs fixing; the name is closed, the *receiver class* is what is open.
* The 6 REVIEWED entries in `wio_unreachable_methods.rb` that pin these sends
  (of 12 total, the other 6 pinning a `respond_to?`) stay: they are the record
  of why the name is still countable as a literal (ADR 0218), and they are
  enforced, not advisory -- removing one without the send fails
  `scripts/wio_strip_scripts_check.rb` (verified: it reports "a reachable site
  dispatches a computed name; review it in WioUnreachable::REVIEWED").
* The new helper names a reader might expect here (`apply_one_stat_mod`,
  `apply_stat_mod_pair`, `party_stat`, `actor_stat`) are not on the tree and
  must not be added by a later attempt without re-measuring: each is a
  `case`-dispatch helper whose cost is the +41 above.

## Triggers to revisit

Run (host `mrbc` prebuilt, `3rd/*` populated):

```sh
MRBC=$PWD/3rd/mruby/build/host/bin/mrbc OUT_DIR=/tmp/w OUT_SYMBOL=rpg2k \
  ruby tools/bc2cpp/bc2cpp.rb \
  mruby-rpg2k/mrblib/game/battle.rb mruby-rpg2k/mrblib/game.rb \
  mruby-rpg2k/mrblib/scene/equip_menu.rb > /tmp/w.log
ruby scripts/bc2cpp_dynamic_site_census.rb /tmp/w.log
```

* The receivers become provable, which is the only thing that makes an arm free:
  a closed-world proof that `flag_of`/`modified_stat`/`draw_stat_row`'s `b`,
  `target` and `a` have a single class (ADR 0331's parameter row, 53 floor-freed
  sites). With the receiver resolved, `respond_to?` and `!` fall away with it and
  the `case` arms become the direct calls the source already reads as.
* `ComputedSend` gains a table source for `%i[...]` literals and for a parameter
  proven by its call sites, so ADR 0303's expansion covers these 8 directly in
  the tool -- still leaving the `send`-not-`__send__` rule to be answered, but
  that rule is a `mruby-metaprog` linking fact, not a proof gap.
