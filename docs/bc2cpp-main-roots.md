# Code generation rooted at the native host

`BC2CPP_MAIN_AST` enables an optional emission pass rooted at the selected
native program's `main`. It does not replace the method-table omission proof:
methods that remain callable by name are additional conservative roots. Only
methods already proven name-invisible may be omitted by this pass. With empty
omission lists, no method bodies are removed.

The ordinary build is unchanged unless this option is set. This is an
experimental build profile; it is not enabled by default for Wio or CI game
builds, and it does not by itself make the Wio image fit.

Closed builds can separately remove proven constructor registrations; see
[tableless initializers](bc2cpp-initializer-tables.md).

## Export the host roots

Use Clang with the preprocessing flags, target and include paths of the host
being built. The native host is `src/main.cxx` on desktop. For Arduino, export
the framework translation unit containing `main` and include the application
translation unit with `--unit`; `setup` alone is not the program root.

```sh
ruby scripts/bc2cpp/main_ast.rb src/main.cxx build/main-roots.json \
  --unit mruby-rgss/src/lib.cxx \
  --unit mruby-rgss/src/input_bridge.cxx \
  --unit mruby-rgss/src/terminal.cxx \
  -- <the target's compiler flags>
export BC2CPP_MAIN_AST="$PWD/build/main-roots.json"
```

`CLANG` selects the Clang executable. When the target is built with GCC, set
`BC2CPP_HOST_CXX` to that target compiler: it preprocesses each input first,
and Clang reads the resulting C++ with the target triple from `-dumpmachine`.
This preserves GCC's selected preprocessor branches rather than substituting
Clang's compiler macros. Unsupported PCH/module inputs and parse failures stop
extraction. GCC-specific preprocessed types must also be understood by the
selected Clang; for example, a GCC/glibc `_Float32` declaration can prevent
extraction. Do not substitute a manifest from a different compiler configuration.
`--unit` can be repeated for linked native
sources whose lookups need analysis. Include every linked host helper that can
call Ruby, such as desktop `src/error_dump.cxx`, as well as the gem bridges.
A declaration in `main` does not expose a helper's separately compiled body.
These units conservatively retain their
function bodies as native callback roots; they are not assumed dead merely
because a direct call from `main` was not found. Unanalyzed native files still
contribute their literal lookup names. An unresolved lookup in a non-core
native file retains every method body until that file has an adequate AST
analysis. The pinned VM's implicit protocol calls remain roots.

The exporter follows function and callback references, static initialization,
and explicitly retained startup/export functions. Overloads are joined by
name. Constructors and indirect function calls conservatively retain possible
function definitions. It resolves literal names, finite conditional choices,
read-only local initializers, presym constants, and static helper parameters
whose direct callers supply finite names. Mutation, address escape, arbitrary
input names and unsupported reflection refuse pruning.

The result is a compact summary, not a saved copy of the entire Clang AST.
Its cache key includes the command, compiler, source files, included headers
and exporter code. Repeating an unchanged export skips Clang and preserves
the output timestamp. Volatile date/time macros are rejected. Changed inputs
invalidate the manifest; consuming a stale manifest fails with instructions
to regenerate it. Export again after bootstrap or presym generation changes
one of the host's headers.

`--lookup-names-only` restricts host name roots to resolved lookup arguments,
instead of retaining every string literal in a reached C++ body. It still
follows callbacks and direct implementation references, and an unresolved
lookup retains all bodies. Include all linked Ruby-calling host helpers;
opaque declarations do not reveal their bodies.

## Use the target's preprocessed native inventory

The native VM rake integration provides `bc2cpp:native-inventory:<build-name>`.
After the ordinary bootstrap build, invoke it using the same build directory
and configuration. For example, from `3rd/mruby`:

```sh
MRUBY_CONFIG=/absolute/path/to/config.rb MRUBY_BUILD_DIR=/absolute/path/to/build \
  rake bc2cpp:native-inventory:closed
```

This exports `<build-dir>/closed/bc2cpp_native_inventory.json` from the actual
presym task's selected `.pi` inputs. Generated Ruby/codegen units are modeled
by their Ruby IR; native exception wrappers map to their original C sources.
Other generated native units remain included. The exporter invokes stale
preprocessing tasks, reads their dependency files and hashes their inputs.
It never needs Clang to parse the GCC runtime's expanded C/C++.

Set `BC2CPP_NATIVE_INVENTORY` to that file along with `BC2CPP_MAIN_AST` for the
next generation. Native reachability roots then come from selected expanded
inputs. Unlinked files, disabled VM/compiler branches and unused macro
definitions contribute no roots. Presym scanning tags preserve lookup names;
ordinary ROM rows and registration destinations define names rather than
look them up. Unfamiliar executable table initializers remain conservative.

This changes the reachability name inventory; type/registration analyses
retain their broader source model. VM protocol names and named entries not
covered by an omission proof remain protected. The shared omission proof
clears the target inventory and host profile so its lists remain independent
of one target's preprocessing flags.

Changed sources, headers, preprocessing outputs or analysis code invalidate
the inventory. Re-export after bootstrap, presym or generated-header changes;
stale inputs fail instead of falling back silently to a raw-source scan.
Changing the inventory regenerates compiled gems. These profiles remain
opt-in; export a separate inventory for each target/configuration.

For tooling that already has an exact unit list, the standalone exporter is:

```sh
ruby scripts/bc2cpp/native_inventory.rb units.json native-inventory.json
```

`units.json` is an array of objects with absolute `source`, `preprocessed` and
`depfile` paths. It must list the selected native units, not an arbitrary
subset of the target. Prefer the rake exporter, which reads the actual build
inventory.

## Prune before emission

The pass starts with the host roots, gem/class initialization, copied method
bodies, constructors, and every method still reachable through the existing
named-call interface. It follows method names to a fixed point, preserving all
owners that could answer each name and all blocks inside a retained body.
An unused method does not contribute calls that would retain its callees.
Direct native `_impl` references are roots even without a Ruby lookup.

The resulting instruction-sequence set filters `CodeGen.compile_all` before
method compilation and emission. Shared generation computes this set once
before forking the per-gem emitters. The full registry and type analyses remain
available, and report-only type checking still checks the full program.

Unreachable methods use the existing mrblib stub planner, including its
load-time and method-copy safety checks. Eligible residual bodies are replaced
by `raise ScriptError`, reducing their native continuation input too; an
unexpected invocation fails visibly. This does not delete arbitrary native
irep metadata or change method-table exclusions. Core dynamic dispatch retains
the already-protected named roots rather than inventing a narrower name set.
An unresolved project-level dynamic lookup conservatively retains all bodies.

For this profile, native dispatch also uses the active preprocessed inputs from
mruby's presym task. A driver descriptor left by an older generation does not
retain continuation branches when its C++ metadata is no longer present. Missing
descriptors for active metadata fail the build; this does not guess which parts
of a retained mrblib program can run.

The generated diagnostics report retained instruction sequences, reasons for
conservative retention, and omitted `Owner#method` keys. The static omission
proof always generates the complete program with this emission profile off,
so its lists remain independent of the selected host. Changing or disabling
the profile invalidates generated C++ in incremental rake builds.

## Explain named registrations

Set `BC2CPP_MAIN_REPORT=/path/to/reports` when invoking the generator with a
host manifest. It writes `<OUT_SYMBOL>_named_reachability.json`, including each
generated registration name (aliases separately), its implementation, proof
exclusion status, and independent bounded-name reachability evidence.

```sh
ruby scripts/bc2cpp/dynamic_names_report.rb \
  --main-report reports/engine_named_reachability.json
ruby scripts/bc2cpp/dynamic_names_report.rb \
  --main-report reports/engine_named_reachability.json --entries
```

The summary counts each remaining slot once, choosing its first available
reason in this order: VM protocol, host AST, direct native implementation,
preprocessed native token, raw native source token, literal lookup, Ruby
instruction, and copied body.
The JSON keeps all reasons and their source locations. Native tokens and host
strings are conservative evidence, not necessarily executed calls. The report
does not seed every registered method as an entry point, and core aliases
reach their original bodies and transitive callees. Block-form eval and
`to_enum(:name, other_arguments)` are distinguished from unbounded names.

Unreached report entries remain registered unless the separate omission proof
authorizes removal. Unresolved forwarding sites are listed explicitly; a low
candidate count is not a proof that computed dispatch cannot reach them.
Removing an alias registration preserves the original implementation and other
aliases. The core omission proof treats registrations and alias destinations
as definitions, and direct implementation references as body roots rather
than named lookup roots. ROM exclusions also apply to generated replacements,
so installing compiled methods cannot put an excluded slot back.

## Validation

```sh
MRBC=/path/to/mrbc BC2CPP_MRUBY_FULL=/path/to/full/host \
  ruby scripts/bc2cpp/main_roots_check.rb
```

This checks callbacks, startup, direct native entries, transitive Ruby calls,
named roots, omitted callers/callees, compiled-versus-interpreted results,
finite native helper arguments, stale headers and unresolved dynamic calls.
