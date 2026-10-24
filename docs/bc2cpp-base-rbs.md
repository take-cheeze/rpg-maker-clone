# Base RBS generation

Generate Ruby and native base declarations for all repository gems with:

```sh
ruby scripts/bc2cpp/base_rbs_all.rb --jobs 2 OUT_DIR CLOSED_BUILD_DIR
```

`CLOSED_BUILD_DIR` supplies generated mruby headers. The output is base stubs
under `OUT_DIR`, separate from the checked-in signature inputs. Native files
need Clang and the headers their gems include. A gem that cannot preprocess
is listed as `native failed` in the report; AST-analysis failures retain the
existing logged fallback to regex return analysis.

Native files use up to two worker processes by default, limited to one on a
single-processor host. `--jobs N` (or `-j N`) sets the limit; `--jobs 1` runs
serially. Ruby implementations without fork support also run serially.
The per-gem generator accepts the same option:

```sh
ruby scripts/bc2cpp/base_rbs_native.rb --jobs 2 OUT_DIR -I INCLUDE_DIR SOURCE.cxx
```

Each worker preprocesses and scans one source. It runs Clang AST extraction
and parses the JSON only if a registered function has a body whose return kind
needs analysis. Files with only class registrations, external function
registrations, or no registrations skip that work. Each file loads its AST at
most once; same-file helper functions remain available to the return analysis.
Preprocessing failures retain their error report without a redundant AST warning.
The parent merges
results and diagnostics in source order, preserving declaration precedence
and skipped registrations. Increasing jobs can reduce wall time but permits
more large Clang ASTs in memory simultaneously. See [ADR 0488](adr/0488-base-rbs-native-file-workers.md).

## Local measurement

Two alternating comparisons took 36.9/37.4 seconds on the baseline and
27.1/26.6 seconds with two workers (26–29% less wall time). All 71 generated
`.rbs` files and stderr diagnostics were byte-identical; report rows matched
after normalizing output-directory paths.
This comparison used CRuby 3.4.9 (historical; the bc2cpp jobs now use Ruby 4.0.5), Clang 21.1.8 and the existing host build's
headers. It excluded two native gems that failed preprocessing because
`oniguruma.h` and `io_hal.h` were unavailable in that environment. These are
base-generation timings, not bc2cpp compilation or game runtime timings.

### Two versus four workers

Four alternating runs of `base_rbs_all.rb --jobs N` over the whole repository
(the `bc2cpp` Nix shell, CRuby 4.0.5, Clang 21.1.8) took 51.9 and 53.5 seconds
with `--jobs 2` and 44.9 and 49.0 seconds with `--jobs 4`. user+sys was about
38 seconds in every run. Peak summed RSS of the process tree was 2.03–2.12 GiB
at either setting, sampled every 20 ms. All generated files, stdout and stderr
were identical across the runs after normalizing the output directory. The host
was shared with other agents (load average up to 6.7 on four cores), so the
wall-time gap of about 11% is within this box's noise.

The default stays at two. `base_section_check.rb` runs this generator inside
the four-wide `ci:parallel` group in `.github/workflows/build.yml`, beside three
other checks on a four-vCPU runner, and ADR 0510 bounds that concurrency. This
measurement ran one generator alone and did not measure that footprint.

Run `ruby scripts/bc2cpp/base_rbs_check.rb` to check scheduling, error handling
and serial/parallel output equivalence. Its native fixture requires Clang.

## Native types

A native declaration's parameters come from the function's one `mrb_get_args`
format (`tools/bc2cpp/native_format_types.rb`: a type only where mruby checks
the class). mruby-math's `get_float_arg` (`mrb_as_float(mrb, mrb_get_arg1(mrb))`)
makes the same check as the `f` format, so it is typed the same, as `Numeric`.
Otherwise the parameters fall back to the arity in the registration's aspec,
untyped.

The return type is the join of the function's returns: from the clang AST
(`tools/bc2cpp/native_ast_returns.rb`), or else from the return text
(`tools/bc2cpp/native_return_kinds.rb`). Only a return expression's outermost
call names a kind, so `mrb_assoc_new(M, mrb_float_value(x), …)` is an `Array`.
For these declarations a join of one kind and nil is optional (`String?`,
`self?`). The compile-time kinds that `scripts/bc2cpp/native_fn_kinds.rb` writes
keep single kinds: an optional join is unproven there. The compiler does not
read these declarations (they give no program hint, TC1005), so they describe
the native API rather than steer code generation.

## Base section in `sig/bc2cpp/declarations.rbs`

The base section of the committed signature file (everything before
`# ---- block_types.rbs`) is the generators' output. Check it against them with

```sh
ruby scripts/bc2cpp/base_section_check.rb CLOSED_BUILD_DIR
```

and rewrite it when the check fails, with

```sh
ruby scripts/bc2cpp/base_section_check.rb --write CLOSED_BUILD_DIR
```

`--write` regenerates the native blocks and the `# Base RBS` declarations and
leaves the rest of the file byte for byte. A declaration the generator no longer
writes is removed; one it writes and the file lacks is appended under its
`# bc2cpp-native:` marker. The later sections (trace-derived and hand-written
tables) have no generator and are not touched. Candidates are promoted into the later sections
with [promote_candidates.rb](bc2cpp-promote-candidates.md), which never writes the base section.

`scripts/bc2cpp/base_section_regen_check.rb` tests the writer on the host, with
fixture generator output and a round trip of the committed file, which must
reproduce it byte for byte. It needs neither clang nor the closed build.

A later lazy-AST comparison on CRuby 4.0.5 + YJIT and Clang 21.1.8 took
21.12/21.45 seconds before this change and 13.33/12.28 seconds after it
(37–43% less wall time), with two workers. AST extractions fell from 51 to 17.
All 71 generated RBS files were byte-identical and the normalized report rows
matched. The same two missing-header native gems were excluded as above.
