- **Native base RBS generation** skips nonbrace text during function-body
  extraction and avoids redundant core-owner regex attempts, reducing repeated
  scanning without changing generated declarations.
