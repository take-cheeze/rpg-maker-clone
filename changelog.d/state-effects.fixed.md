- **Blind now blinds, a blow now wakes a sleeper, and Silence now silences.**
  The battle read four of a state's fields (action restriction, slip damage,
  hold turn, auto-release) and left the rest of the 状態 table unread — including
  the three that give the most familiar statuses in the genre their whole meaning
  (ADR 0032):
  - **`reduce_hit_ratio`** scales the afflicted attacker's accuracy, the lowest
    ratio winning when several states apply. Nine of Nepheshel's 25 states carry
    one and two of mtf-meido-action's ten do; mtf's Blind should cut accuracy to
    a fifth, and it is `reduce_hit_ratio` and nothing else, so it used to be
    purely cosmetic. Measured against the real tables, a 90% base becomes 19.6%
    under mtf's Blind and 44.6% under Nepheshel's 恐怖.
  - **`release_by_attack`** rolls after a normal attack the target survives, so
    hitting a sleeping battler wakes it — Nepheshel's 睡眠 on 80% of blows, mtf's
    Sleep on 50%. Sleep used to last out its own timer however hard it was hit.
    Normal attacks only, matching RPG_RT; a skill never shakes a status loose.
  - **`restrict_skill` / `restrict_magic`** seal a skill whose physical / magical
    rate reaches the state's threshold. 封印 and 恐怖 in one game and Silence in
    the other all set it and all left their victim casting freely. A sealed
    actor's skills come off the battle menu and a sealed enemy's action entry no
    longer fires.

  Nothing else moved: running every troop in both test beds (157 and 88 fights)
  gives byte-identical results to before — the same outcomes, the same 1847 and
  1726 swings, the same 501 and 708 misses. The new code only fires when a state
  actually carries the field.
