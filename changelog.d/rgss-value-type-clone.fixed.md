- **`Color`, `Tone`, `Rect` and `Table` survive `#clone` / `#dup`.** mruby's
  clone/dup allocate a bare object of the same class and copy only its instance
  variables, so a copied value type carried no native payload and the first read
  raised "uninitialized RGSS::Tone". A game's own scripts copy these constantly —
  `@tone_target = tone.clone` in `Game_Screen`, `@flash_color = color.clone`, a
  map's fog tone, a picture's — so anything that tinted or flashed the screen
  ended the game. The four types now define `initialize_copy`, which is what
  clone and dup call. (`Bitmap#clone` is still unimplemented: it needs a real
  pixel copy.)
- A script-host **timeout is no longer reported as a crash**. It is how a
  headless run ends — the driver already treated it as a clean end — but it was
  being printed as `section "Main" raised RGSS::Timeout` with a backtrace, which
  made a passing run read like a broken one.
