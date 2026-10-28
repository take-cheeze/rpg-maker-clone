# The compiled gems table

Which gems bc2cpp generates code for, and what each one owns, is data in
`tools/bc2cpp/compiled_gems.yml`, not Ruby code. One entry per `mruby-*-compiled`
gem, in the order the tools iterate them:

```yaml
version: 1
gems:
  mruby-rgss-compiled:
    owners_from: mruby-rgss      # or `core`
    out_symbol: rgss_compiled
    native_namespaces: [RGSS]    # optional
```

- `owners_from` names where the owners come from; the list itself is never
  written down. `mruby-<gem>` is every engine class or module with a plain `def`
  in that gem's mrblib, plus the core classes it reopens (`bc2cpp_gem_owners`,
  `tools/bc2cpp/gem_owners.rb`). `core` is mruby's own classes
  (`BC2CPP_CORE_OWNERS`, scanned from `3rd/mruby`).
- `out_symbol` is the `OUT_SYMBOL` of the gem's generated files, unique across
  gems.
- `native_namespaces` are the namespaces whose native registrations the gem's
  registration removes when the closed list leaves them out.

The file's comments hold the per-gem design rules (what the owners are, what
stays interpreted, why `StringIO` and `Array` are reopened, ...).

`tools/bc2cpp/compiled_gems_config.rb` reads and validates the file and raises on
anything unexpected: unknown keys, a missing `owners_from` or `out_symbol`, a
duplicate `out_symbol` or gem key, an owners source that is neither `core` nor a
gem name, a malformed namespace list. `compiled_gems.rb` then resolves the owners
and exposes the result as `BC2CPP_COMPILED_GEMS`, the table every consumer
(`build_config.rb`, the `*-compiled` `mrbgem.rake` files, the codegen and the
checks) already read. The `*-compiled` rake rules and the CMake build list the
file as a prerequisite, so editing it regenerates the gems.

`scripts/bc2cpp/compiled_gems_config_check.rb` holds a fixture for the good file
and one per validation failure, and checks the repository's file against the gems
on disk.
