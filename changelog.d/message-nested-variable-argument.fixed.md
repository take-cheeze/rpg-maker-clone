- **`\N[]`/`\V[]` message control codes now accept a nested `\V[n]` as their
  own argument** (yado.tk: `\N[\V[1]]` names the actor whose id is variable
  1's *value*, and `\V[\V[1]]` displays variable 1's value indirectly). The
  bracket reader `Game::Message.read_bracket` used to stop at the first `]`
  it saw, so `\N[\V[1]]` read its argument as the literal text `"\V[1"` (an
  actor id of 0, since `.to_i` on that string is 0) and left the outer `]`
  behind as stray text in the message. It now balances nested `[`/`]` pairs,
  and a new `Game::Message.resolve_arg` recursively unwraps a `\v[]`/`\V[]`
  argument to the variable's value before it reaches the actor-name/variable
  lookup; a plain numeric argument (`\N[5]`, `\V[1]`) resolves exactly as
  before. Covered by a new `scripts/rpg2k_logic_check.rb` check, confirmed
  to fail against the pre-fix code.
