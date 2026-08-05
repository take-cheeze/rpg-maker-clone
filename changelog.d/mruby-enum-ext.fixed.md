Added `mruby-enum-ext` to the engine's gem set so `Enumerable#sort_by` (and
`min_by` / `max_by` / `group_by`) work in the built engine. These are absent
from the default mruby gem set, so code that called `Array#sort_by` — the
RPG2000 battle turn-order and message-pacing paths — raised `NoMethodError` and
aborted the native binary at runtime, even though the CRuby host checks passed.
