MRuby::Gem::Specification.new('hal-wio-io') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'Wio Terminal (bare-metal arm-none-eabi) HAL for mruby-io'

  # HAL gem depends on the feature gem, mirroring hal-posix-io/hal-win-io --
  # mruby-io's own mrbgem.rake auto-selects a HAL only when it sees no
  # `hal-*-io` gem already active, and build_config.rb's `if wio` block adds
  # this one explicitly before rpg_maker_gems pulls mruby-io in.
  add_dependency 'mruby-io', core: 'mruby-io'
end
