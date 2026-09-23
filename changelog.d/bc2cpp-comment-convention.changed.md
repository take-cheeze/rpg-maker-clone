- **bc2cpp comments** in `tools/bc2cpp/*.rb` now follow a new
  "explain why, briefly -- history goes in the ADR" convention (documented in
  `AGENTS.md`): about 20,600 comment lines condensed to about 5,600, with
  `bc2cpp.rb` going from 1.54 MB to 0.75 MB. Code is unchanged. The new
  `scripts/bc2cpp_comment_only_check.rb` proves a comment-only change by
  comparing the Prism ASTs of two git refs.
