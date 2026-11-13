- **bc2cpp:** an identifier-shaped string literal and the pieces of a name built
  at run time no longer keep method-table entries, while every native that
  turns a String into a method name is an audited one (`name_sinks_check`
  lists them; a new one keeps the old rules until it is audited). The closed
  RPG2000 build drops 20 engine entries (the single-letter `y`/`z` accessors
  of the name-entry grid, the `*data` names, `none?`).
