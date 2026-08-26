- **Save/Load:** a shown picture's save-file record now matches RPG_RT's
  real byte layout: it carries the position last given to Show Picture
  (distinct from its current and target position while a Move Picture is
  in flight) alongside its live position, and its zoom/transparency/tone
  values are each written only when off their own default rather than
  always present or, for a picture at rest, missing its live values
  entirely. Previously this codebase modeled neither the shown position
  nor a resting picture's live zoom/transparency/tone at all, producing
  saves with a different byte shape than a genuine RPG_RT save.
