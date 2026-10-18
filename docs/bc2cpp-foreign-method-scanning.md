# bc2cpp foreign method scanning

`ClosedWorld#outside_ruby_definer_paths` and `#outside_ruby_paths_defining`
share `#outside_ruby_path_method_names`, which reads and scans each foreign
Ruby file once per `ClosedWorld` instance. The former previously bypassed
that memo, repeating the Prism tree walk and conservative regex scans for
every distinct method name, even though the parse tree itself was cached.

This reuses the existing per-world cache: source inputs remain fixed during
one world's analysis, and a new world reads current contents. Definition
collection, path ordering, duplicate paths and absent-name results retain
their previous behavior.

A local CRuby 3.4.9 benchmark queried the first 300 sorted method names from
39 mruby core and core-gem Ruby files. Each of three alternating baseline and
patched runs used a fresh world and cleared `RubyParseCache` before querying
`outside_ruby_definer_paths`. Baseline times were 2.659, 2.627 and 2.529
seconds; patched times were 0.024, 0.027 and 0.026 seconds. The marshalled
query results had identical SHA-256 hashes. This measures the query path,
not total generator or generated-game performance.

`scripts/bc2cpp/ruby_parse_cache_check.rb` checks both query families against
uncached scans, including multiple definitions, accessor names, absent names,
path ordering and duplicates. It counts file scans to catch repeated work
and checks that a new world sees rewritten sources.
