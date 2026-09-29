- **bc2cpp** builds every irep (labels, pool, symbols, local names, tree) from
  mrbc's RITE binary; the C-dump regex parse and the `mrbc -v` text loader
  (`BC2CPP_TEXT_LOADER`) are removed, and all symbol spellings now decode
  exactly (ADR 0251). Generated output is unchanged.
