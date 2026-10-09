- **bc2cpp: `skill_stat_mod_keys` and 8 more names return a proven class again** — a literal-block send on a
  not-yet-classed receiver no longer drops its name from RETURN_CLASS_TABLE; exact-receiver `attr_reader` results
  read their slot's pool (docs/adr/0378). By-name sends 2,086 to 2,082.
