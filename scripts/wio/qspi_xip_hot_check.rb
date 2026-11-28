#!/usr/bin/env ruby
# frozen_string_literal: true

# STABLE_GLOB (scripts/wio/qspi_xip_hot.rb): a hot-list line keeps naming its function across a rebuild that renames
# bc2cpp's hashed namespaces, renumbers its constant accessors and block bodies, or clones the function differently,
# and does not widen to unrelated functions.
#
#   ruby scripts/wio/qspi_xip_hot_check.rb      # pure Ruby

require_relative 'qspi_xip_hot'

$failures = 0
def check(name, ok, detail = nil)
  if ok
    puts "ok   #{name}"
  else
    $failures += 1
    puts "FAIL #{name}#{detail ? " -- #{detail}" : ''}"
  end
end

# [name before, the same function after a rebuild, an unrelated function the line must not match]
CASES = [
  %w[_Z37RGSS__Audio_singleton_bgm_volume_impl9mrb_valueS_.isra.0
     _Z37RGSS__Audio_singleton_bgm_volume_impl9mrb_value
     _Z38RGSS__Audio_singleton_bgm_volume2_impl9mrb_value],
  %w[_ZN27bc2cpp_shard_rpg2k_compiled18bc2cpp_native_slotEP9mrb_state9mrb_valueiRN26bc2cpp_cs_2284d4dd461ff30212bc2cpp_xslotEl.constprop.0
     _ZN27bc2cpp_shard_rpg2k_compiled18bc2cpp_native_slotEP9mrb_state9mrb_valueiRN26bc2cpp_cs_99999999999999992bc2cpp_xslotEl
     _ZN25bc2cpp_shard_lcf_compiled18bc2cpp_native_slotEP9mrb_state9mrb_value],
  %w[_ZN25bc2cpp_shard_lcf_compiled15bc2cpp_cconst_9Ev
     _ZN25bc2cpp_shard_lcf_compiled17bc2cpp_cconst_311Ev
     _ZN27bc2cpp_shard_rpg2k_compiled15bc2cpp_cconst_9Ev],
  %w[_ZN26bc2cpp_cs_911db493762370f331bc2cpp_compact_c3817f1cac95443fEP9mrb_state9mrb_valueS2_
     _ZN26bc2cpp_cs_0123456789abcdef31bc2cpp_compact_c3817f1cac95443fEP9mrb_state9mrb_valueS2_
     _ZN26bc2cpp_cs_911db493762370f331bc2cpp_compact_d3817f1cac95443fEP9mrb_state9mrb_valueS2_],
  %w[_ZL60RPG2k__Scene__Map_pages_changed$3f_block_fallback_177_directP9mrb_stateP4REnvblPK9mrb_value
     _ZL59RPG2k__Scene__Map_pages_changed$3f_block_fallback_12_directP9mrb_stateP4REnvblPK9mrb_value
     _ZL54RPG2k__Scene__Map_update_block_fallback_177_directP9mrb_stateP4REnvblPK9mrb_value],
  %w[some_c_function.part.0 some_c_function.part.3 some_c_function_two]
].freeze

CASES.each do |before, after, other|
  glob = stable_glob(before)
  check("#{glob} matches #{before}", File.fnmatch(glob, before))
  check("#{glob} matches #{after}", File.fnmatch(glob, after))
  check("#{glob} does not match #{other}", !File.fnmatch(glob, other))
end
check('a plain C name stays exact', stable_glob('rpg_maker_init_lcf') == 'rpg_maker_init_lcf')

if $failures.zero?
  puts 'qspi_xip_hot_check: PASS'
else
  puts "qspi_xip_hot_check: FAIL (#{$failures})"
  exit 1
end
