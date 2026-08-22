- **Save/Continue:** a picture saved mid-`Move Picture` now resumes gliding
  from exactly where it was toward its target, matching RPG_RT -- previously
  it silently snapped straight to the move's finish position the instant a
  save reloaded, because two save-format fields this codebase's own schema
  had mislabelled as the picture's live position were actually the move's
  target, a gap that a still picture (where the two happen to coincide)
  could never expose.
