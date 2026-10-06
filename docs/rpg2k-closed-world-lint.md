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
| `Dynamic/GlobalVariableReassignment` | A global variable written at multiple sites, or in a repeatable context (method, block or loop) |
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
check instead of `rescue nil`. An LCF record, section list or file has no
dotted field access at all (ADR 0213): read a field with `row[:name]` (or
`row[name]` for a computed name) and ask whether the schema declares it with
`LCF.field?(row, :name)`, never `send`/`respond_to?`. When a use is genuinely
data-driven, allow it in place with a reason:

```ruby
value = obj.send(accessor) # rpg2k-lint:allow Dynamic/Send -- accessor names come from a fixed table
```

See ADR 0212. bc2cpp itself re-runs this lint on every closed-world build and
aborts when it fails or disagrees with the `ClosedWorld` analysis (ADR 0368).

The wio build's unreachable-method strip (ADR 0218) relies on the same
property: a method counts as reachable only when some literal spells its name.
A computed `send`, `respond_to?`, `method` or `to_sym` in the wio build's
mrblib therefore also has to be listed, with where its names come from, in
`WioUnreachable::REVIEWED` (`scripts/wio_unreachable_methods.rb`), or the wio
build and `scripts/wio_strip_scripts_check.rb` fail.

The bc2cpp closed-world dispatch analysis also recognizes calls to
`Exception#message` whose receiver traces to a rescued exception register. The
generated operation follows mruby's `exc_to_s` message/default-string behavior;
it declines the shortcut when a Ruby instance override or runtime definition can
replace `message`.

## Rescues in the compiled Ruby (ADR 0262)

`scripts/impossible_as_error_check.rb` (CI `ruby-checks`) requires every broad
`rescue` (`StandardError`, `Exception` or bare) in those gems to report to
`$stderr` or `RGSS.warn_once`, and rejects `rescue` modifiers. Catch the
narrowest class instead where one expresses the recovery (`NameError` for a
launcher constant a host harness never defines). bc2cpp does not compile a
`rescue` naming several classes, so use one class per clause.
