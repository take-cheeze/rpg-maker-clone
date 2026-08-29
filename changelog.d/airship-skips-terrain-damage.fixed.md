- **Riding the airship now skips terrain damage and the RPG2003 footstep SE
  entirely**, ported from a reference implementation's player-movement code,
  not independently confirmed against genuine RPG_RT under wine, which
  returns before ever looking up the stepped-on tile's terrain while
  airborne. A boat or
  ship still takes terrain damage as usual, since they sail the water
  layer's own terrain rather than flying over it.
