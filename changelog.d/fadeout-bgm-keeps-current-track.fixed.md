- **Interpreter:** Fade Out BGM no longer forgets which track was playing --
  matching RPG_RT's own BGM-fade handling, ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine: the current-BGM record survives an ordinary fade untouched. Previously a Memorize BGM taken after
  a fade memorised silence instead of the faded track, a Save taken right
  after a fade forgot the track on Continue, and disembarking a vehicle or
  ending a battle/inn stay shortly after a fade restored silence instead of
  resuming it.
