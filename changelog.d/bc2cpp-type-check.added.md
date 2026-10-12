- `scripts/bc2cpp/type_check.rb`: a report-only type check over bc2cpp's whole-program inference. It prints the
  inferred parameter, return, ivar and constant types, the reason bucket for what could not be typed, annotations that
  contradict the inference or are ignored (with `file:line:col`), and the declarations whose signature would act on the
  most by-name sends; `--format json|tsv` for tools (ADR 0412, `docs/bc2cpp-type-check.md`).
