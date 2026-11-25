- **bc2cpp: a destructure of an Array of proven length reads its elements directly.** When `a, b = v` reads a
  fresh literal, or the result of a call whose every definition returns a literal of one length, each element is
  loaded with no Array test, bounds check or nil fallback; a source proven an Array keeps only the bounds check.
  A `BC2CPP_CLASS_REACH_VERIFY` build checks length and class at every such read; `BC2CPP_FIXED_TUPLE=0` turns it
  off. Wio firmware: 1,736 bytes smaller.
