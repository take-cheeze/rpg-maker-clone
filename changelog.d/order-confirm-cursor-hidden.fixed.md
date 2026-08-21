- **UI:** the field Order (party reorder) screen's left column now hides its
  selection cursor entirely once every member has been picked and the
  Confirm/Redo prompt opens, instead of leaving it frozen on the now-blank
  final row -- matching RPG_RT, which explicitly clears that column's
  selection at this one transition. Redo still correctly restores the
  cursor when picking resumes.
