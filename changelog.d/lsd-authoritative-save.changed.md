- **The `.lsd` is now the authoritative save.** A Save writes only
  `Save<NN>.lsd`, and it carries every field the Marshal dump does. The fields
  the liblcf chunks could not hold exactly (weather, encounter total, the boarded
  vehicle, common-event progress, the flash peak duration and power, exact picture
  opacity and target, an erased picture's name) go in a project chunk, 200, in the
  same file. Old `save<N>.mrb` saves still load, and a file this engine wrote
  takes precedence over an older Marshal save in the same slot. Setting
  `RPG2K_SAVE_MARSHAL_FIRST=1` restores the old Marshal-first order. See
  docs/adr/0395. wio keeps its Marshal-only saves (`from_lsd` stays excluded there,
  for the flash budget in docs/adr/0128).
