- `scripts/rpg2k_testbed_logic_check.rb` no longer false-positives on two of
  its checks against a real game whose content does not match the shape the
  first two test beds happened to have:
  - "fixed-id commands reach actor N while away" used to assert that running
    a companion's own fixed-actor-id commands changed something observable in
    a snapshot — a stand-in for "the lookup did not silently drop it" with no
    direct hook into the private resolution methods. That proxy fails on a
    command sequence that is a legitimate no-op run back-to-back outside its
    narrative context (Full Heal on an already-healthy actor, a variable-
    sourced Change Level delta with the variable unset, a name change
    immediately undone by a second one). It now calls the interpreter's own
    `#stat_targets`/`#identity_target` directly, which is the actual lookup
    ADR 0030 fixed and the thing worth protecting against regressing.
  - "a blinding state cuts accuracy" derived its expected value as the
    unafflicted hit chance scaled by the state's `reduce_hit_ratio`, which
    only holds when the state does nothing else and attacker/target AGI are
    equal — not true of a state that pairs the ratio with `affect_agility`
    (a "charge up" mechanic: harder to land, but hits harder). It now asserts
    against `#hit_modifier` directly, the one figure `reduce_hit_ratio` alone
    controls.
  - Four checks (revive items, map-slip states, damaging terrain, curative
    medicine) required a non-empty initial party, hard-failing on a real game
    that starts with none (its whole party joins through intro events) — the
    same shape `mz_testbed_check.rb`'s own empty-party fix already covers for
    MZ. They now print a "skipped" line and move on, matching how the menu
    check already handled a partyless game.
