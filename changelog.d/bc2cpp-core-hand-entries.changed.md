- **bc2cpp** calls `Array#push` (2 to 4 arguments), `Array#replace`, `String#to_s`, `String#getbyte` and
  `String#to_i(base)` directly on an exact receiver, through new hand-audited entries. `getbyte` and `to_i` are taken
  for a fixnum argument and `replace` for an Array argument; any other argument keeps the by-name send.
