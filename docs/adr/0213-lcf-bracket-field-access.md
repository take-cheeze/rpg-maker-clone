# 0213. LCF fields are read with `[]`, not through method_missing

Date: 2026-09-23

## Status

Accepted

## Context

`LCF::Array1D` (one record), `LCF::Sections` (a map tree's sections) and
`LCF::File` (the `.ldb`/`.lmt`/`.lmu`/`.lsd` wrapper) answered dotted field
access through `method_missing`: `row.hp_max` looked the name up in the
record's schema, `tree.initial` returned a section, and `db.actor` forwarded
any unknown name to the root with `__send__`. `respond_to_missing?` answered
`row.respond_to?(:hp_max)` with "the schema declares it", which the runtime
used as a guard in front of about 300 field reads.

ADR 0138 added Symbol-keyed `[]`/`key?` and moved the call sites its traced
run reached, keeping `method_missing` as a safety net. That net is what the
closed-world compile cannot see through: a class with `method_missing` can
answer any name, so bc2cpp cannot prove any call whose receiver might be a
record (ADR 0212 lints for it). Generating one reader method per schema field
(ADR 0211's approach, not merged) made the calls provable, but added about
80 KB to the compiled LCF gem and 89 KB to the compiled rpg2k gem at `-Os`.

## Decision

Field access is `[]` only. The three `method_missing` /
`respond_to_missing?` pairs are deleted, and every caller reads
`row[:hp_max]`, `tree[:initial]`, `db[:actor]` (or `row[name]` for a computed
name, always a Symbol). A stray dotted read now raises `NoMethodError`.

- `Array1D#field?(sym)` answers "does this record's schema declare the
  field", exactly what `respond_to_missing?` answered; `Sections#field?` and
  `File#field?` are the section and file counterparts. `field?` is not
  `key?`: `key?` means the chunk is present in the file.
- `LCF.field?(obj, name)` replaces the `obj.respond_to?(:name)` guards whose
  receiver can be a record. For an LCF record, section list or file it asks
  the schema; for anything else (nil for an absent row, a plain value, a check
  harness's stand-in record) it calls `respond_to?`, so every guard gives the
  answer it gave before for every receiver.
- `File#delete` forwards to the root record, the one root method (besides
  `[]`, `[]=` and `key?`) that a caller reached through the old catch-all
  forwarding (`scripts/rpg2k_logic_check.rb`, `scripts/gen-rpg2k-save.rb`).
- Computed `send`/`__send__` calls whose receiver is a record
  (`row.send(name)`, `db.system.send("#{type}_name")`) became `row[name]`;
  string-built names became dynamic Symbols. `send` on game objects is left
  alone (a separate concern).
- `mruby-lcf-compiled/src/register.cxx` no longer registers the compiled
  `Array1D#method_missing`; the new `#field?` methods are not registered and
  stay interpreted.

How the call sites were found. Many schema field names are also methods of
game objects (`name`, `x`, `hp`, `level`, ...), so a name search only yields
candidates: 2,143 dotted calls in the three gems' mrblib use a schema field
name, 1,795 of them a name some game class also defines. Each candidate was
classified by its receiver's provenance (a local's assignment or block
parameter, an ivar's writes, a helper's callers), giving 819 converted reads.
Every candidate whose name no game class defines was converted. The static
set was then checked against two traces:

- Before the change, the three hooks were instrumented to log their caller.
  Every host harness plus five test beds (Nepheshel R/N, kk1.12, histoire,
  yumenikki) in nine native modes each (title, New Game, two battle plays, map
  editor, chipset editor, animation preview, effect and audio probes) reached
  336 runtime lines (159 lines of `respond_to?` guards). Every traced dotted
  read is in the converted set; the rest of the traced lines were the computed
  `send`s above.
- After the change, the hooks were re-added as log-only stand-ins keeping the
  new behaviour. The same runs logged no runtime hit, and no harness hit
  except `scripts/lcf_schema_coverage.rb` probing `obj.each` inside a bare
  `rescue` (a TypeError before, a NoMethodError now; both rescued).

The host scripts and tests that read real game data were converted the same
way; the check harnesses' stand-in records gained `[]` where they lacked it
(`FixtureFields` in `scripts/rpg2k_logic_check.rb`, and a few singletons).

## Consequences

- A record, section or file answers no field name as a method.
  `scripts/lcf_bracket_access_check.rb` (CI ruby-checks, coverage report)
  fails if a hook or a field-named method comes back, and compares `[]` with
  the removed dotted lookup on real Nepheshel records.
- LCF's decode and caching are unchanged: `[]` is the path the dotted form
  already took.
- Under CRuby, `db.system` used to reach the private `Kernel#system` through
  `File#method_missing`'s `__send__`, so the harnesses logged
  `screen transition defaults unreadable`. `db[:system]` reads the System
  record there too; the message is gone. The engine under mruby was never
  affected.
- The closed-world lint baseline loses the six LCF hook entries, the `__send__`
  forwarder and 28 computed `send`s (70 offences to 35). The 14 rescue
  modifiers in `Scene::Map` are unchanged in number, but they now read
  `u[:parallax_flag] rescue false` and so on, so their baseline entries were
  re-keyed (`--accept-new`) rather than added.
- Compiled size grows slightly. bc2cpp cannot type most receivers, so every
  `x[:name]` is an untyped `GETIDX`: 2,320 sites against 1,486 before. Since
  ADR 0216 each generic site is one call to the outlined `bc2cpp_getidx`
  helper, which calls the compiled `Array1D#[]` directly. A dotted read of a
  name only LCF answered used to be one `mrb_funcall` into the interpreted
  `method_missing`. x86-64 `-Os` `.text` of each compiled gem's `register.o`
  (the build's own flags plus `-Os`), on top of ADR 0216:

  | gem | before | after | change |
  | --- | ---: | ---: | ---: |
  | mruby-lcf-compiled | 52,398 | 51,100 | -1,298 |
  | mruby-rpg2k-compiled | 3,871,095 | 3,913,107 | +42,012 (+1.1%) |
  | mruby-rgss-compiled | 167,508 | 167,909 | +401 |

  Without ADR 0216's helper the same change cost the rpg2k gem +399,613
  bytes (+9.4%), which is why it landed after ADR 0216. Typing the receiver
  (a record read from `db[:item][id]` is always an Array1D) would shrink the
  remaining cost further; that is a follow-up.
- `tools/bc2cpp/bc2cpp.rb`'s `ZSUPER_NATIVE_TARGETS` still names the deleted
  LCF `respond_to_missing?`/`method_missing` methods. The entries are keyed
  lookups and never match now; removing them (and possibly the whole native
  zsuper path) is a follow-up.
