- A battle scene builds its troop, `Game::Battle` and event interpreter when it
  is created, and hands them to its `Ui`, so the bc2cpp declarations name the
  fight's model fields with no nil. The compiled battle scene drops its nil
  tests on them, and Wio flash shrinks.
