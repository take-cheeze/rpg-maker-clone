- **A revive item can no longer be spent as a potion.** The item row's `ko_only`
  (蘇生専用) was unread, and all four items that set it across the test beds —
  Nepheshel's ドラゴンブラッド, ドラゴンハート and 気付け薬 and mtf-meido-action's
  Stimulant — cure 戦闘不能 *and* restore 25 / 100 / 3 / 25 percent of max HP.
  Reading the flag as nothing did not just let the cure fire pointlessly on a
  living ally (it is a no-op there anyway); it let the **HP restore** fire, so
  every one of them worked as a percentage heal on a standing member, and the
  menu offered them as effective. RPG_RT returns from the item algorithm before
  *both* effects, so the answer is "does nothing at all". The rule gates the menu
  and, per target, the use itself — so an all-party revive passes over the
  members who never fell rather than topping them up. See ADR 0039.
