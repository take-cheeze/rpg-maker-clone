- **RPG2000/2003 messages:** `\N[]`/`\V[]`/`\C[]`/`\S[]` bracket arguments now
  parse character-by-character like RPG_RT's own `Game_Message::ParseParam`,
  instead of extracting the raw substring up to the first `]` and re-parsing
  it. A literal digit run and a nested `\V[]` reference in the same bracket
  now concatenate (`\N[1\V[2]]` with variable 2 = 45 names actor 145, not
  actor 1), nested `\V[]` resolution is capped at one level deep as in real
  RPG_RT (a second nesting level, e.g. `\V[\V[\V[1]]]`, is left unevaluated
  and its own closing bracket is dropped into the message as stray text
  rather than being consumed), and an unrecognised character inside a
  bracket now stops further digit accumulation while keeping the value
  already read, rather than being silently absorbed. Covered by two new
  `scripts/rpg2k_logic_check.rb` checks.
