- **Autonomous event movement:** a blocked move (Random/Vertical-cycle/
  Horizontal-cycle/Approach/Away Player alike) no longer turns the event to
  face the obstruction on every single failed attempt -- ported from a
  reference implementation's own blocked-move handling, not independently
  confirmed against genuine RPG_RT under wine: it reverts
  that facing change back on the overwhelming majority of blocked
  attempts, only letting it settle once genuinely stuck for a sustained
  stretch. Previously, an NPC repeatedly drawing a blocked direction near a
  wall or another blocking event visibly snapped its sprite to face
  whatever direction it just failed to enter, reading as a twitchy,
  spinning NPC instead of holding its last successful facing steady.
