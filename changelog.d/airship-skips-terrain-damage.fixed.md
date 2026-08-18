- **Riding the airship now skips terrain damage and the RPG2003 footstep SE
  entirely**, matching EasyRPG's `Game_Player::Move`, which returns before
  ever looking up the stepped-on tile's terrain while airborne. A boat or
  ship still takes terrain damage as usual, since they sail the water
  layer's own terrain rather than flying over it.
