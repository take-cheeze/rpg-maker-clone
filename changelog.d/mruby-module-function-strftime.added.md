- **XP / VX / VX Ace** two more real mruby gaps found continuing to boot a
  real VX Ace game's bundled community scripts, both fixed: bare
  (argument-less) `module_function` — CRuby's "declaration mode", where every
  `def` that follows in the same scope becomes both a private instance method
  and a public singleton method — was a documented no-op in this mruby
  version; a module built entirely under a bare declaration (e.g. a bundled
  error-log utility whose public entry point is only ever reachable as
  `SomeModule.method_name(...)`) silently defined no singleton methods at
  all. Reimplemented via `method_added`, without touching the vendored mruby
  core. `Time#strftime` did not exist — mruby-time never bound a Ruby-level
  method taking a format string, so formatting a timestamp for a log line or
  a save filename (completely ordinary) raised `NoMethodError`. Implemented
  in pure Ruby over `Time`'s existing component accessors, covering the
  common directive set real scripts use.
