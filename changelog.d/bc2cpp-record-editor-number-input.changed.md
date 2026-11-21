- **bc2cpp**: the map scene's Input Number widget (`@number_input`) and the
  debug menu's variable editor (`@editor`) are declared record types, so
  `ni[:model].digits` and `ni[:contents].clear` compile as direct calls
  instead of owner calls.
