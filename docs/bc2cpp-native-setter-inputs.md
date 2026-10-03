# Native setter inputs

`BC2CPP_NATIVE_SETTER_REPORT=/tmp/setters.json` asks bc2cpp to report the named
`contents=` and `bitmap=` input candidates after C++ emission. For the full Wio
world, use the existing census command:

```sh
BC2CPP_NATIVE_SETTER_REPORT=/tmp/setters.json MRBC=/path/to/mrbc \
  ruby scripts/bc2cpp_coverage_report.rb
```

The command performs diagnostic and shipped passes; the final JSON describes the
shipped pass. The report changes no generated C++. A write failure is surfaced.

The schema has `schema_version: 1` and `diagnostic_only: true`. `contracts` identifies
native writer families, whether source scoping was audited, input forwarding behavior
and named candidate counts. `caller_completeness` remains `not_proven`, and
`native_family_pooling` remains false. `sites` records setter name, source, owner,
irep/index/opcode, argument count, receiver/input class masks and blockers. Dispatch
is explicitly a named candidate, not a proven native call. `mentions` contains
Symbol/String stems and definitions; `computed_names_present` covers compiled
bytecode's name-producing operations. Missing/zero/opaque masks are unresolved.

On ADR 0337's parent Wio tree:

| Setter | Named sites | Input facts | Other blockers |
| --- | ---: | --- | --- |
| contents= | 62 | All Bitmap | Six unresolved receivers; computed names and outside caller coverage remain unproved |
| bitmap= | 31 | 23 Bitmap, one Bitmap-or-nil, seven unknown | Computed names and outside caller coverage remain unproved |

The seven unknown bitmap inputs occur in `RGSS::Graphics.transition`,
`RPG2k::Window#contents=`, and Scene::Battle's `build_actor_sprite`, `build_battle_back`,
`build_battle_sprites`, `rebuild_battler_sprite` and `reveal_battle_monster`.
They are the next producer/parameter facts to investigate. They already have proven
Sprite receivers, so classifying their values is a separate problem from dispatch.

Native setters store arbitrary arguments unchanged, before helpers that may raise.
The compiler therefore keeps Sprite/Plane/Window native slots unproved. It can
isolate native bitmap writes to Sprite/Plane and let unrelated Ruby classes prove
their own `@bitmap` fields, including a Window's independent bitmap field.
`BC2CPP_NATIVE_BITMAP_IVAR_SCOPE=0` withdraws this isolation; the original
`BC2CPP_NATIVE_IVAR_SCOPES=0` withdraws every native scope.

A future input proof must enumerate dynamic and outside callers, distinguish Ruby
and native setter lookup, and join all native constructor values and Ruby writes.
The current report is evidence for that work, not permission to assume Bitmap-only
inputs. See [ADR 0337](adr/0337-bc2cpp-native-setter-input-audit.md).
