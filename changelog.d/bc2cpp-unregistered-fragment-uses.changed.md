- **bc2cpp**: the closed build's unregistration proof counts a string-pool literal as a piece of a built method name
  only when a load of it may reach a built string. A literal only compared, looked up as a native hash key, tested
  for in a constant list or put into a string with a space or a colon no longer keeps `state*` / `*command` /
  `sell*` methods registered. The closed list grows from 1587 to 1644 names.
