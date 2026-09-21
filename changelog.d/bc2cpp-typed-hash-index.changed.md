- **bc2cpp** preserves Ruby indexed-access dispatch when an Array or Hash
  annotation does not match the runtime receiver, and recognizes built-in
  Array and Hash argument annotations even when the core class has no methods
  in the closed-world registry.
