# RPG2k closed-world lint

bc2cpp compiles the Ruby in `mruby-rpg2k`, `mruby-lcf` and `mruby-rgss` as a
closed world. A compiled call can skip dynamic dispatch only when every method
it might reach is visible to that analysis, so these constructs are linted:

| Cop | Flags |
| --- | --- |
| `Dynamic/MethodMissing` | `method_missing`, `respond_to_missing?` |
| `Dynamic/Send` | `send`/`public_send`/`__send__` with a computed name |
| `Dynamic/ConstReflection` | `const_get`/`const_set`/`remove_const`/`autoload`, `const_missing` |
| `Dynamic/IvarReflection` | `instance_variable_get`/`set`/`defined?`, `remove_instance_variable` |
| `Dynamic/MethodDefinition` | `define_method`, `alias`/`alias_method`, `undef`, `remove_method` |
| `Dynamic/Eval` | `eval`, `instance_eval`/`class_eval`, `*_exec`, `binding`, `method(...)` |
| `Dynamic/Extend` | `obj.extend` on anything but `self` |
| `Dynamic/RescueModifier` | `expr rescue value` |

```sh
ruby scripts/rpg2k_closed_world_lint.rb                       # check
ruby scripts/rpg2k_closed_world_lint.rb --regenerate-baseline # after fixing offences
```

Existing offences are listed in `scripts/rpg2k_closed_world_lint_baseline.txt`.
The baseline only shrinks: fixing an offence requires regenerating it, and
regenerating refuses new entries unless given `--accept-new`. Prefer explicit
code: a real method instead of `method_missing`, a `case` or direct call instead
of `send(name)`, an explicit mapping instead of `const_get`, and an explicit nil
check instead of `rescue nil`. When a use is genuinely data-driven, allow it in
place with a reason:

```ruby
value = row.send(field) # rpg2k-lint:allow Dynamic/Send -- field names come from the LCF schema
```

See ADR 0212.
