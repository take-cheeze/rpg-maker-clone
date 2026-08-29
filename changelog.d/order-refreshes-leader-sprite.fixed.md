- **Order screen:** Confirming a party reorder now refreshes the leader's
  on-map sprite immediately -- ported from a reference implementation's own
  order-confirmation handling, not independently confirmed against genuine
  RPG_RT under wine, which resets the map sprite as part of adding or
  removing a party member when applying the new order. Previously, promoting a member whose
  CharSet graphic differs from the previous leader's left the hero visibly
  wearing the old leader's sprite until some unrelated event refreshed it.
