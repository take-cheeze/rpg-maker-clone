- **bc2cpp** stops treating verified Math domain-error labels as method lookups
  when the closed-world literal-lookup proof holds, allowing unused Math methods
  to be pruned without changing their error messages in other builds.
