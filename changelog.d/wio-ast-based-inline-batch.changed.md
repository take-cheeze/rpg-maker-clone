- **Wio Terminal: folded 106 more single-caller helper methods into their
  call site(s), on top of ADR 129's 18.** Same wio-only, checked-in-source-
  untouched mechanism (`strip_wio_inline_helpers.rb`), but the candidates
  and their exact call-site splices were found and generated via
  `RubyVM::AbstractSyntaxTree` instead of text/token scanning -- the real
  fix for the three bug classes that stopped ADR 129's own broader
  automation attempt (a wrong call-site line, a `:symbol` literal
  mistaken for a real call, multi-line calls and `rescue`/`ensure` bodies
  corrupting the splice). New this round: 50 candidates whose `return` is
  confined to leading guard clauses (`return E if C; REST`) are now
  inlined too, either as an `unless`-wrapped statement (call site discards
  the value) or a paren-wrapped nested ternary (call site uses it) --
  previously excluded outright by ADR 129's "no `return`" rule. Every one
  of the 133 candidates found was individually verified with a real
  `mrbc` compile before any of them were combined; three real
  cross-candidate interaction problems (21 candidates that call each
  other, one that calls an ADR 129 method also being inlined, three
  same-line collisions) were found and excluded before writing anything,
  and a real substring-collision bug in the generator itself (a bare call
  like `draw_arrow` matching as a text prefix of `draw_arrow_visibility`
  elsewhere in the file) was caught and fixed by anchoring every
  substitution to end-of-line.
  Real `mrbc --remove-lv` compile of the wio-shaped `rbfiles` list, run
  through this file's own unmodified rewrite mechanism: 477,883 ->
  465,506 bytes (12,377-byte reduction, on top of ADR 129's own). See
  ADR 131.
