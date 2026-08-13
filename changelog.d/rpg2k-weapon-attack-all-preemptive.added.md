- RPG Maker 2000: two more weapon combat flags are read now — **`attack_all`**
  (全体化) and **`preemptive`** (先制攻撃), both left unread before this.
  `Game::Actor#attack_all?` / `#preemptive?` follow the same weapon-only
  `equipment_flag?` shape as `#ignores_evasion?`. A weapon flagged `attack_all`
  spreads its wielder's basic Attack across every living member of the
  already-resolved target's side (`Battle#side_targets`, `#swing_side` /
  `#attack_side`) instead of just the one chosen target — including under a
  forced attack-enemy/attack-ally restriction (berserk/confusion), and
  including the attacker itself when confusion turns the target's own side
  into the one being spread across (EasyRPG's `Normal::vStart` / `AddTargets`
  has no self-exclusion). A weapon flagged `preemptive` jumps its wielder's
  basic Attack to the front of that round's turn order
  (`Battle#turn_order` / `#preemptive_boost?`) — only a basic Attack
  qualifies; a Skill, Item or Defend with the same weapon still equipped
  keeps its ordinary agility slot, matching EasyRPG's `CreateExecutionOrder`'s
  own `Type::Normal` guard. Covered by new `scripts/rpg2k_logic_check.rb`
  checks.
