- RPG Maker 2000: the **Control Variables** command now reads **item counts** and
  the **party size**. Operand type 4 (item) was previously unhandled and silently
  returned the item id; it now returns the number of that item held in the bag
  (mode 0) or the number equipped across the whole party (mode 1, each equipping
  slot counted), matching a reference implementation's behavior (not
  independently confirmed against genuine RPG_RT under wine). Operand type 7
  (other game quantities) gained selector 2, the number of party members, next to
  the existing gold and timer selectors. So an event can branch on "how many
  Potions do I have", "is the sword equipped", or "how big is the party". Covered
  by new `scripts/rpg2k_logic_check.rb` checks (held vs equipped item counts, and
  the party-size selector). The event-reference operand (type 6 — an event's or
  the hero's map id / position / facing) remains a follow-up.
