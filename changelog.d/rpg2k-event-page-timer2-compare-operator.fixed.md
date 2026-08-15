- **A map event page's RPG2003-only Timer2 condition is now consulted, and
  its variable condition now reads RPG2003's own comparison operator
  instead of always testing `>=`.** Confirmed against EasyRPG Player's
  source: RPG2003 lets a page condition compare a variable with `==`, `<=`,
  `>`, `<`, or `!=`, not only `>=`, and adds a second Timer condition
  alongside the original. Both fields were already parsed from the
  database but never consulted. Fixing the variable comparison also
  surfaced and corrected a wrong schema default that would have flipped
  every untouched RPG2003 page's variable condition from `>=` to `==` once
  read.
