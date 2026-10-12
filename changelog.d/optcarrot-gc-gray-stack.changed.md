- **Optcarrot benchmark:** use a larger native-host GC gray stack to reduce
  overflow heap rescans, with `OPTCARROT_GRAY_STACK_SIZE` controls and separate
  build targets for consistent VM/gem layouts.
