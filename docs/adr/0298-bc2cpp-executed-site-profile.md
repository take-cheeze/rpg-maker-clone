# 0298. bc2cpp ranks its remaining dynamic sites by executed count

Date: 2026-10-01

## Status

Accepted

## Context

`scripts/bc2cpp_dynamic_site_census.rb` (docs/bc2cpp-dynamic-site-census.md) counts the by-name dispatch
left in generated C++ and says why each `bc2cpp_send` site stayed dynamic. Every one of those counts is a
static count: a site reached once at start-up weighs the same as one inside the optcarrot CPU loop. The
proofs of ADR 0289, 0295, 0296 and 0297 each removed a few hundred sites, and nothing said whether the
sites that were left are the ones the program spends its time in. Choosing the next proof by static count
can spend a week on a long tail that never runs.

The census already classifies sites from the generated text, and the generated text is the only place a
site's guard chain, `POLY_DIAG` line and neighbouring family marker are all visible. A profile has to key
its counters to that same text.

## Decision

Add an opt-in executed-count profile (`SITE_PROFILE`), kept entirely out of code generation:

- `BC2CPP_SITE_PROFILE=DIR` makes `tools/bc2cpp/bc2cpp.rb` hold its stdout and, on a clean exit, hand it to
  `tools/bc2cpp/site_profile.rb`. That rewrites each `bc2cpp_send(M, ...` and
  `mrb_funcall{,_id,_argv,_with_block}(M, ...` call to `(bc2cpp_site_hit_<symbol>(ID), fn)(M, ...`, prepends
  a counter table and an `atexit` dump, and writes `DIR/<OUT_SYMBOL>.sites.tsv` (id, kind, generated line,
  enclosing function, method name, reason category, guard shape, receiver origin, family marker). Unset, the
  output is byte-identical and `site_profile.rb` is never loaded.
- A binary built from that output writes `$BC2CPP_SITE_PROFILE_OUT/<symbol>.<pid>.hits` (`id<TAB>count`,
  non-zero only) at exit; without the variable it writes nothing.
- The reason categories moved out of the census script into `tools/bc2cpp/site_census.rb`, so the static
  census and the profile name a site and its reason from one implementation. The census output is unchanged
  except that the `--tsv` function column now follows non-`static` bodies instead of keeping the previous
  static function's name.
- `scripts/bc2cpp_dynamic_site_census.rb --rank SITES_DIR --workload NAME=HITS_DIR ...`
  (`tools/bc2cpp/site_rank.rb`) joins the two and prints the hottest sites, hits per reason category with the
  proof lever that category points at, and hits per method name. A hit file from another build is refused.
- `tools/optcarrot_probe/compiled_run.rb` passes the switch to the pass whose C++ it builds and, in this mode,
  runs only the compiled binary against CRuby (checksum still compared), not the 60 s interpreter run. The game
  builds pick the switch up from the environment through their `mrbgem.rake` `sh env, cmd` calls.
- `scripts/bc2cpp_site_profile_check.rb` instruments a miniature of the generated shape, builds and runs it with
  g++, ranks the dump, and (with `MRBC`) proves bc2cpp's output with the switch equals the plain output once the
  counters are peeled off. It runs in the `fast` shard of the `bc2cpp-checks` job.

## Consequences

- The next proof can be chosen by what runs. The lever column is per reason category, not per site: a category
  names why codegen kept the site, not whether the proof exists.
- A count is the calls that reach the site, which for a fast-path else-arm is the guard misses. A site in a
  shared helper (`bc2cpp_getidx`, ...) counts every caller together; its lever is the helper's callers.
- The hit counters are plain increments, not atomic; a multi-threaded workload undercounts. Timings of an
  instrumented build are meaningless and must not be published.
- Only workloads someone can run are measured. The game smoke needs the SDL engine and an RPG2000 project, which
  CI has and this tool does not supply; the report states which workloads it covers.
- Counter arrays are static per translation unit, so two compiled gems linked into one binary dump two files.
- Sites in a `mrb_yield_argv` call are not counted: it is a block call, not a by-name method dispatch.
