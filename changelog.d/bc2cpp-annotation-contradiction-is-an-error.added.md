- **bc2cpp:** a `# bc2cpp:` annotation that contradicts a proved type is now a build error
  (`RBS_SEED_CONTRADICTION`). Only `:fixnum` against `:symbol` counts as a contradiction; nil
  literals, class names and unknown types never do.
