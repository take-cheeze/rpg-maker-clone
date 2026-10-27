- **`scripts/bc2cpp/dynamic_names_report.rb`** says why each compiled engine
  method, attr accessor or RGSS native the closed build keeps in its method
  table is still there: the first source that made its name dynamic (a C
  string literal in generated code, a Symbol literal, a file that names it, a
  send in code that may run as bytecode, a name fragment, ...), with a summary
  of the sources that keep the most entries.
