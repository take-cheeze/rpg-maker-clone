- **bc2cpp** declares every blockless Enumerable iterator that returns an Enumerator as the method-level union of its
  two forms: the blockless overload (`Enumerator[untyped, untyped]`, with the argument count it accepts) and the
  block overload. The loader refuses a declaration that has only one form (ADR 0524).
