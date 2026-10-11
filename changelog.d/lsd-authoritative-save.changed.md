- **The `.lsd` is the authoritative save.** A Save writes only `Save<NN>.lsd`,
  and it carries every `Game::State` field. The fields the liblcf chunks could not
  hold exactly (weather, encounter total, the boarded vehicle, common-event
  progress, the flash peak duration and power, exact picture opacity and target,
  an erased picture's name) go in a project chunk, 200, in the same file. See
  docs/adr/0395 and docs/adr/0399.
