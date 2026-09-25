- **bc2cpp** now proves direct module-body ivar assignments for singleton
  receiver analysis, allowing `RGSS::Input#update`'s two `Array#each_index`
  blocks to use native loops and removing two cfunc/RProc fallbacks.
