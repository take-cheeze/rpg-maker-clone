- **The shop screen now shows the database's post-transaction confirmation.**
  `mruby-lcf/mrblib/schema.rb` already decoded `shop_purchased1/2/3` and
  `shop_sold1/2/3` (RPG2000's three shopkeeper "voices"), but nothing in
  `mruby-rpg2k` ever read them: a buy or sell committed silently and dropped
  the player straight back on the list. `Scene::Map` gains a `:purchased` /
  `:sold` screen state, entered right after `Game::Shop#buy` / `#sell`
  commits: `#shop_terms` resolves the right voice (English fallback on a
  blank field, matching every other shop term), `#shop_header` draws it as
  the screen's single line, and it is dismissed on a button press — like
  every other message panel in this scene — back to the buy / sell list it
  came from. Verified against a reference implementation's own shop screen
  (not independently confirmed against genuine RPG_RT under wine): its
  bought/sold modes draw the raw term with no item-name/price
  interpolation and return to the buy/sell list respectively; this port swaps
  their fixed one-second timer for the same button-driven dismissal used
  everywhere else in the scene, since the transition itself already returns
  to the same list. Covered by two new `scripts/rpg2k_scene_check.rb` checks
  (buy and sell) confirming the term text shows and the list reappears after
  the dismiss.
