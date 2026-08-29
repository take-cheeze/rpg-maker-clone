- **RPG2000/2003 maps:** Boarding a vehicle whose BGM is left unconfigured
  (blank database field, no Change System BGM override) now silences
  whatever field music was playing, and disembarking onto a map with no BGM
  of its own now silences the vehicle's music the same way — matching
  a reference implementation's own BGM-playback handling, not independently
  confirmed against genuine RPG_RT under wine, where a blank track means "play
  nothing" and stops the current track rather than leaving the previous one
  running. Previously both cases left the wrong track playing right through
  the transition. Covered by two new `scripts/rpg2k_scene_check.rb` checks.
