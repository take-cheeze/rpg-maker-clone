- **bc2cpp** now devirtualizes zero-argument `Array#first` for exact base Array
  receivers while preserving dynamic dispatch for subclasses and overrides.
