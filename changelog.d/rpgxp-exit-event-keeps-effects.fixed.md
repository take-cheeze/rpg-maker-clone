- RPG Maker **XP**: a list that ends with **Exit Event Processing** (115) — or is
  stopped by a teleport — no longer discards the effects the commands before it
  produced. `Interpreter#stop` cleared every queued side-effect request, and it
  runs inside the same `update` the map scene drains afterwards, so a Set Move
  Route, screen tone, Set Event Location, picture, screen flash/shake, animation
  or script that came before the 115 went out with the list that produced it.
  Those commands had already run; ending the list does not un-run them. The
  queues are still emptied by `start` (a fresh run) and at construction, which is
  where a stale request genuinely should not survive. Found while adding the
  Script command, whose effect is the most visible: nothing happened at all.
