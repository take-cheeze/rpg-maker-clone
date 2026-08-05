- **Equipment combat flags now do what they advertise.** Four RPG2000 fields the
  schema parsed and the runtime never read (ADR 0033):
  - **二刀流 `dual_attack`** — the weapon swings twice per basic attack. Thirteen
    of Nepheshel's weapons promise a second blow and delivered one. The second
    swing is skipped when the first fells the target, the same rule the enemy's
    own dual-attack action already followed.
  - **必中 `ignore_evasion`** — the attack drops the agility term from the to-hit
    roll, leaving the weapon's own hit rate. Thirteen more of Nepheshel's weapons
    promise never to miss and missed; against an agility-999 foe the ダガー goes
    from 82% to 98%. The wielder's *own* blindness still applies, since what the
    flag ignores is the target's evasion.
  - **MP消費半分 `half_sp_cost`** — skills cost half, rounded up so a 1-SP skill
    still costs 1. Any slot grants it (Nepheshel's 賢者の指輪 is an accessory);
    a 7-SP skill drops to 4.
  - **強力防御 `strong_defence`** — Defend halves damage a *second* time, a
    quarter rather than a half. Seven of Nepheshel's fifty actors have it,
    including リト, its hero: 41 damage while guarding becomes 20.

  Nothing else moved — every troop in both test beds (157 and 88 fights) gives
  byte-identical results, since neither starting party wears the flagged gear.
- **`scripts/rpg2k_testbed_logic_check.rb`** additionally asserts against the real
  item and actor tables that every 二刀流 weapon grants two strikes, every 必中
  weapon hits at its own rate against an unhittable target, and every MP消費半分
  item halves a real skill's cost.
