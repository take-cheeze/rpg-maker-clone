- **Move Type "Random":** a Random-moving event now rolls a *relative* turn
  off its own current facing -- ported from a reference implementation's
  own random-movement handling, not independently confirmed against genuine
  RPG_RT under wine, which continues straight most of the time
  (30%), turns 90° left (20%) or right (20%), turns 180° (10%), or skips the
  move attempt entirely for that tick (20%) -- instead of restarting in a
  fresh, independent absolute cardinal direction every single step.
  Previously, a "Random"-moving NPC spun between the four cardinal
  directions with no continuity between steps; real RPG_RT's Random movers
  read as noticeably more purposeful, tending to wander mostly straight
  with occasional turns.
