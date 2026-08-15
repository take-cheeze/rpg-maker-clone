- **Berserk (attack-enemy) now correctly beats Confusion (attack-ally) when
  a battler is afflicted by both at once**, instead of Confusion winning.
  `Game::Battle#battler_restriction` used to pick whichever restriction had
  the larger raw database constant (`RESTRICTION_ATTACK_ALLY` = 3 vs
  `RESTRICTION_ATTACK_ENEMY` = 2), which happens to get real RPG_RT's
  priority backwards. EasyRPG Player's `State::GetSignificantRestriction`
  (`src/state.cpp`) instead resolves a fixed hierarchy by restriction type —
  do_nothing > attack_enemy > attack_ally > normal — while scanning every
  afflicted state, with asymmetric upgrade rules (attack_enemy overrides
  attack_ally or normal; attack_ally only overrides normal; a do_nothing
  state anywhere short-circuits immediately). This matches デフォ戦bot's own
  trivia: "同時に暴走と混乱の状態になった場合、暴走が優先されて敵を攻撃する"
  ("Berserk and Confusion together: Berserk takes priority and attacks the
  enemy"). `battler_restriction` now implements that same hierarchy.
  Covered by new `scripts/rpg2k_logic_check.rb` checks, confirmed to fail
  against the pre-fix code before the fix.
