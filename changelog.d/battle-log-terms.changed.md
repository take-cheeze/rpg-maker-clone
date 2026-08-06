- **The battle log speaks the game's own language.** It used to invent its
  English ("Hero hits Slime for 42", "Slime defends") in a runtime for games that
  are not in English and that ship their own wording for every one of those
  lines. RPG2000 keeps them in the 用語 table as *predicates* the battler's name
  goes in front of, and both test beds fill in **126 of the 127 fields** while
  the runtime read two. `Game::States::BattleText` now composes them and the log
  prints what the battler did and then what it did to the target, as RPG_RT does:
  「スライムの攻撃！」 then 「リトは 7 のダメージを受けた！」 — including the
  particle rule that is not in the database (に for one of theirs, は for one of
  yours). Covers every basic action (attack, Defend, Observe, Charge,
  self-destruct, flee, transform), both damage sides, no-damage and misses. A
  blank term drops the whole entry back to the composed English, so an
  English-release table with half the block empty still reads. Skills and items
  keep their composed line until their own `using_message` is read, and the
  critical-hit line is left alone because which side keys `actor_critical` /
  `enemy_critical` is genuinely unclear. See ADR 0036.
