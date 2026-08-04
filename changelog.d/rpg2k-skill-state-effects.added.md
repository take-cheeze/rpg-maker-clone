- RPG Maker 2000: **field skills now change status conditions**. `cast_skill`
  applies a skill's `state_effects` (a 0/1 byte per state, index `i` → state id
  `i+1`) to its targets — **curing** them by default and **inflicting** them when
  `reverse_state_effect` is set (the opposite polarity to items, where the reverse
  flag marks the cure). The field path is **deterministic** (no accuracy roll),
  matching EasyRPG's `Game_Battler::UseSkill`, and states are applied **before**
  HP/SP recovery: a revive skill that cures the death state (戦闘不能) stands the
  ally back up so its recovery then lands, while a plain heal still can't touch a
  downed ally. `skill_effective?` now reports a cure/inflict skill as usable even
  when HP/SP are full (so a status skill isn't greyed out), and such a skill only
  spends SP when it actually changed something. Grounded against EasyRPG's field
  `Game_Battler::UseSkill` (scope self/ally/party, `reverse_state_effect` polarity,
  no to-hit). Covered by new `scripts/rpg2k_logic_check.rb` checks (cure only the
  listed states, revive-then-heal, a plain heal not reviving, inflict via the
  reverse flag, and the no-op on an unafflicted target). Inflicting states in
  **battle** (rolling `state_chance`) remains a follow-up.
