- **RPG2000/2003 battles:** A weapon whose own hit rate is a deliberate 0%
  now actually gives its wielder a 0% basic-attack hit rate, matching
  RPG_RT's own `INT_MIN` "nothing equipped" sentinel. Previously a
  "cursed" weapon like this was silently treated as if no weapon were
  equipped at all, handing its wielder the 90% unarmed default instead of
  the intended chance to always miss. Covered by a new
  `scripts/rpg2k_logic_check.rb` check.
