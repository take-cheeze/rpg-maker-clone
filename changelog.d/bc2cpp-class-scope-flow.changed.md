- bc2cpp resolves class-body outer scopes through bytecode IR aliases, joins,
  loops and handlers, requiring every reaching path to agree on the qualified
  name before class-name and constructor-pool analysis use it.
