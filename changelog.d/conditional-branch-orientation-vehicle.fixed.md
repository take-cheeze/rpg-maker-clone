- **Conditional Branch's character-orientation condition (type 6) now
  resolves a vehicle reference** (10002 boat / 10003 ship / 10004 airship),
  matching Control Variables' identical operand 6 attr 3 lookup. Previously
  a vehicle ref fell through to `nil` and the condition always read false.
