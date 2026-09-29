- Closed-world constructor resolution now selects the innermost declared class
  or module binding when a constant name is repeated in nested lexical scopes,
  matching Ruby's constant lookup order.
