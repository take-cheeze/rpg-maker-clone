- **Change System BGM** (10660) and **Change System SFX** (10670) overrides
  now round-trip through a real `.lsd` Save/Continue, not just the portable
  `Marshal` save — `Game::State#to_lsd` writes every populated slot into its
  `SAVE_SYSTEM` field (BGM 72-74/79-82, SFX 91-102) and `.from_lsd` reads them
  back.
