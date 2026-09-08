- The map-walk port (iPod nano 7G and Wio Terminal) now draws **map events**
  as static sprites: any event whose initially-active page carries a CharSet
  graphic (the interpreter's own page-selection logic, run against a fresh
  save's switches/variables/party state), drawn before or after the hero
  depending on its page's below/same/above-characters layer and, for the
  same-as-hero layer, its row relative to the player -- the genuine
  renderer's own draw-order rule, not a new one. One frame each, picked once
  at export time and never animated on-device, the same "no live game state"
  limit already accepted for the hero's own sprite. Costs up to 472 bytes of
  device code and, at each target's chosen caps (64 event pictures / 1024
  events on the nano, 16 / 1024 on the Wio), up to roughly 55 KB more RAM,
  reserved whether or not a given export actually carries any -- measured
  17,940 bytes on the Wio's real 66.1%-full budget for Nepheshel's own
  worst-case map (256 sprited events, 12 distinct pictures). A chip-graphic
  event (a chipset tile rather than a CharSet frame) is not drawn yet. Format
  version 7: re-export before installing. See ADR 102.
