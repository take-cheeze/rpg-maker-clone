- **bc2cpp (Wio Terminal):** `RGSS::Bitmap#font` is declared to return an `RGSS::Font`, checked once in its own body,
  so the 55 `bitmap.font.color = ...` sends in mruby-rpg2k drop their owner-class guards and NoMethodError fallbacks.
