- **XP / VX / VX Ace** `RGSS::Sprite#width`/`#height` — RGSS3 (VX Ace) added
  these over XP/VX's `Sprite`, read-only, mirroring the sprite's own
  `bitmap` dimensions (`0` with none set). `Window` and `Graphics` both
  already had `#width`/`#height`; only `Sprite` was missing them. Found
  continuing to boot a real VX Ace release's bundled scripts: its own
  speech-bubble add-on reads `@tail.height` (`@tail` a real `Sprite.new`) to
  centre its tail sprite under a message window, which raised
  `NoMethodError` the first time the game showed a message.
