- **Save files are `Save<N>.lsd` only, on every build.** The Marshal `save<N>.mrb`
  format is gone: a save writes `Save<N>.lsd` alone, and wio now writes and reads
  the `.lsd` too (it had its own Marshal-only save before). `RPG2K_SAVE_MARSHAL_FIRST`
  is removed. **Breaking for players with older saves:** a slot holding only a
  `save<N>.mrb` written before this version now counts as empty. Finish or re-create
  those saves before updating. See docs/adr/0399.
