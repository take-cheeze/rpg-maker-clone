- **bc2cpp**: the FIXNUM_RETURN_IVAR_HINT probe CodeGen embeds no ivars instead of running the embedding probes
  (a cleanliness compile of every embedding `#initialize` and its callees). Its proof only has to be a subset of the
  final facts, which an empty layout is; the closed RPG2000 world and the optcarrot probe generate the same code. The
  probe went from 15.4 s to 1.2 s of the shared generation (6.6 s net per run).
