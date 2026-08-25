- **Shop screen:** the native Buy/Sell/Leave command menu (shown when an
  Open Shop event allows both buying and selling) now matches RPG_RT's real
  layout — the description bar and goods-list window are still drawn, but
  both stay blank, and the Buy/Sell/Leave choices themselves render merged
  into the bottom prompt window below the shopkeeper's greeting, the same
  way this codebase's own Inn Accept/Cancel prompt already works.
  Previously the command choices were drawn into the goods-list window
  itself, a screen real RPG_RT never puts them on.
