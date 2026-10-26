- **Optcarrot probe**: `tools/optcarrot_probe/compiled_run.rb` now times CRuby twice, as the plain interpreter
  (`RUBY_YJIT_ENABLE=0`, plus `--disable=jit` where accepted) and with `--yjit` when that Ruby has YJIT
  (`OPTCARROT_CRUBY_YJIT=0` skips it). Each row records its `RUBY_DESCRIPTION`, both must match the checksum, and
  the summary gives the mruby and bc2cpp ratios against both. Before, CRuby ran once with whatever JIT setting the
  shell had, and the result never said which; the older CRuby figures in the probe README are now marked
  "JIT state not recorded".
