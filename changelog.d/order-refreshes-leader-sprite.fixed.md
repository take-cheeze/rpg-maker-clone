- **Order screen:** Confirming a party reorder now refreshes the leader's
  on-map sprite immediately -- matching RPG_RT's own `Scene_Order::Confirm`,
  which resets the map sprite via `Game_Party::AddActor`/`RemoveActor` as
  part of applying the new order. Previously, promoting a member whose
  CharSet graphic differs from the previous leader's left the hero visibly
  wearing the old leader's sprite until some unrelated event refreshed it.
