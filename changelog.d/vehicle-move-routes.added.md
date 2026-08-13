- **A Move Event / Set Move Route can now drive a boat, ship, or airship**
  directly, previously a silent no-op. A route steps a `Game::Character`
  mirror against the vehicle's own passability (`vehicle_passable?`,
  inheriting the existing ship-specific Through-Mode event-blocking rule),
  writing the result back onto the vehicle each step; unlike the player or
  events, a moving vehicle snaps tile to tile rather than sliding, matching
  the existing Set Vehicle Location feel. A route on the currently-ridden
  vehicle is dropped, since the party's own vehicle-following already
  claims its position every frame. Change / Trade Event Location can now
  target a vehicle too, and Proceed With Movement correctly waits on a
  vehicle's forced route. A route's own Change Graphic sub-command applies
  visibly without persisting to the saved vehicle data, reverting on
  Transfer Player or save/load, the same shape as the equivalent hero
  override. Smooth position interpolation, walk-cycle animation, and
  hero/event collision with a moving unboarded vehicle remain unaddressed,
  left as explicit follow-ups.
