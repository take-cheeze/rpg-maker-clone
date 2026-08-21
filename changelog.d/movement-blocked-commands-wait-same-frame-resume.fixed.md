- **Events:** Proceed With Movement, and a blocked Show/Move/Erase Picture,
  Transfer Player / Recall to Location, Battle Processing / Enemy
  Encounter, or "show message"-flagged Change EXP / Change Level command,
  now resume the very next command the same real frame the forced route
  finishes or the blocking message window closes, matching RPG_RT --
  previously each cost one further frame before the following command ran,
  for both the foreground event and a Parallel Process's own interpreter.
