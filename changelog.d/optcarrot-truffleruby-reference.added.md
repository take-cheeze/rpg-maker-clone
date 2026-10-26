- The optcarrot benchmark (`tools/optcarrot_probe/compiled_run.rb`) can time TruffleRuby as one more reference:
  `OPTCARROT_TRUFFLERUBY=/path/to/truffleruby/bin/ruby` adds a row on the same bundle that must match the checksum
  and appears in the summary ratios. Checked by `scripts/optcarrot/cruby_runs_check.rb`.
