- `scripts/bc2cpp/type_check.rb --iterate N` closes the return-suggestion loop: accepted returns feed the next round as
  signatures for up to N rounds, and candidates are written only once they converge. A derived return is accepted only
  when its return contracts were accepted in the previous round, so cycles never justify themselves. Off by default.
  See `docs/bc2cpp-ir-feedback.md`.
