- The closed bc2cpp build declares the parameter types of 15 more engine
  methods (battle targets, face and sound names, message segment lists,
  state ids) after reading their callers. The declarations are checked on
  entry, and they remove 12 owner calls (1276 -> 1264).
