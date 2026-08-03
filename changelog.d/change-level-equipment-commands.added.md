- The event interpreter now handles the **Change Level** (10420) and **Change
  Equipment** (10440) commands. Change Level adds/subtracts a const or variable
  amount to the target actors' level, rescaling their base stats through the
  growth curve; Change Equipment equips an item (const, or an id read from a
  variable) into the slot matching its type, or removes a slot's gear — folding
  the bonus into the actor's effective stats. Confirmed against real Nepheshel
  events (e.g. actor 3 equipping armour 127). Covered by the logic checks.
