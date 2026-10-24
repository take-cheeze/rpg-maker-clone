- **bc2cpp** applies the hand-audited core direct entries inside compiled mruby core bodies too, so `Array#replace`,
  `String#to_i` and the other entries are used where those bodies call them. New entries cover
  `Range#__empty_range?`, `Array#__fetch` (a fixnum index) and `String#byteslice` (fixnum arguments; a Range argument
  keeps the send).
