- Absent LCF fields with a lazy (`-> { ... }`) schema default now resolve to the
  default's **value** instead of the `Proc` itself, so edition-dependent defaults
  like an actor's `max_level` and the `exp_basic`/`exp_increase`/`exp_correction`
  curve read as numbers (e.g. `50`/`30`) rather than an un-called lambda.
