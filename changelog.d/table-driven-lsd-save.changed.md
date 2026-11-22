- **Saves: the load check and the elided save fields are table-driven.** A save is
  checked on load by walking its schema (`LCF::SaveTyped::Record#check!`) instead of
  one generated method per table, and `Game::State#to_lsd` writes its "omit at
  default" fields through one `[id, value, default]` table loop. Save files are
  byte-identical; the Wio image is smaller.
