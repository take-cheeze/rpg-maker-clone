- **Save/Continue:** a shown picture now survives this engine's own
  internal quick-resume save (the `.mrb` file Continue prefers over a
  genuine `.lsd` when both exist), including one still mid-`Move Picture`,
  which now resumes gliding from its live position toward its target exactly
  as a genuine-`.lsd` Continue already did. Previously the quick-resume path
  silently dropped every currently-shown picture on resume -- it round-tripped
  switches, timers, the screen tint and vehicles, but never mentioned
  pictures at all.
