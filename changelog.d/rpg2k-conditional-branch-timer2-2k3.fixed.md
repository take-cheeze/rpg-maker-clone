- **A Conditional Branch's "second timer" (Timer2) check is now
  RPG2003-only.** It used to be evaluated on any database, so a stray type-10
  condition byte on an RPG2000 project would compare against Timer2 live
  instead of reading as permanently unmet, since the RPG2000 editor has no
  controls for this condition type at all.
