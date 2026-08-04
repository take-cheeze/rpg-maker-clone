- RPG Maker 2000: **"forced action" status restrictions now steer a battler's
  attack**, completing the battle `restriction` handling (alongside the existing
  "do nothing" skip). A state with `restriction` 2 (berserk / provoke) forces the
  battler into a basic attack on a random living **enemy** even when it was told
  to defend or cast, and `restriction` 3 (confused) sends that attack at a random
  member of its **own side** (itself included) instead of the enemy — so a
  confusion spell turns a foe against its allies, and a berserk state denies the
  target its chosen command. The restriction overrides the queued command / defend
  for that turn; the values follow `lcf::rpg::State::Restriction`. Covered by new
  `scripts/rpg2k_logic_check.rb` checks (a confused battler spares the enemy and
  hits its own side; a berserk battler attacks despite a defend command). Enemy-
  cast infliction remains the main state-system follow-up.
