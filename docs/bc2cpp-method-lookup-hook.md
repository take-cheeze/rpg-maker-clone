# Optional by-name lookup hook

The mruby fork provides `MRB_USE_METHOD_LOOKUP_HOOK`. It adds a per-state
`method_lookup_hook` observer to `mrb_state` and notifies it after each
`mrb_vm_find_method` search, including cache hits, inherited methods, misses
and explicit undefined entries. This shared path handles generated C++, native
mruby callers and VM sends. With the define absent, neither the field nor the
notification wrapper is compiled.

```c
void observe(mrb_state *mrb, struct RClass *start, struct RClass *owner,
             mrb_sym name, const mrb_method_t *method);

mrb->method_lookup_hook = observe;
/* ... */
mrb->method_lookup_hook = NULL;
```

The observer sees the starting lookup class and the defining owner. `owner`
is NULL when `MRB_METHOD_UNDEF_P(*method)` is true. It does not change the
lookup result. The method pointer is valid only during the callback; class
pointers are borrowed and are not GC roots. The callback must not allocate
mruby objects, dispatch Ruby, raise, or mutate method tables. Store native
counters or write a native trace instead. Each state's hook starts as NULL.

This observes **lookups**, including `respond_to?` and other probes. It does
not imply a method was called. Direct compiled calls, already-resolved
`mrb_funcall_with_method` calls and VM-specialized operations bypassing method
lookup do not produce events. An unobserved entry is not proof it can be
removed: startup, other games and unexplored branches also matter.

## Closed host tracing

Build both the library and host with the same option because the define
changes the state layout:

```sh
BC2CPP_METHOD_LOOKUP_HOOK=1 scripts/bc2cpp/closed_build.bash BUILD_DIR
BC2CPP_METHOD_LOOKUP_HOOK=1 BC2CPP_HOST_LOOKUPS=/tmp/lookups.tsv \
  scripts/bc2cpp/trace_host.bash BUILD_DIR GAME_DIR
```

The host installs its observer after `mrb_open`, so gem initialization is not
included. Each TSV row records starting class address, defining owner address,
symbol ID, hex-encoded name bytes and found/missing status. Addresses and IDs
are meaningful only within that process; hex encoding preserves arbitrary
symbol bytes. The host rejects trace requests when built without the hook.
The generic hook can be installed earlier by an embedding that initializes
mruby in stages.

## Regression check

`ruby scripts/bc2cpp/method_lookup_hook_check.rb` builds three small mruby
variants: disabled, enabled with caching, and enabled without caching. It tests
native calls, bytecode sends, inherited owner resolution, cache hits, probes,
undefined entries, misses and independent states. `MRUBY_LOOKUP_SOURCE` can
point at an isolated checkout of the fork without changing local submodules.
