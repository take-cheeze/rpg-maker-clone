MRuby::Gem::Specification.new('mruby-wolf') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'WOLF RPG Editor (Woditor) data layer and runtime'

  # Wolf::Project#read / .project? use File. Everything else in the data
  # layer is pure Array/String logic with no other dependency, save for
  # src/lz4.cxx's native Wolf::LZ4.decompress (picked up automatically --
  # mrbgems compile every src/*.cxx with no rbfiles-style listing needed),
  # which needs nothing beyond mruby's own headers.
  add_dependency 'mruby-io'
  # Kernel#sprintf: every error message that formats a byte value uses it
  # (`sprintf("... 0x%02x ...", ...)`). Not in the default gem set -- declared
  # here (not just relied on via build_config.rb's shared gem list) so the
  # per-gem `rake test` binary has it too; see AGENTS.md's note on this exact
  # trap (mruby-mvjs hit the equivalent one with Array#-).
  add_dependency 'mruby-sprintf'
  # runtime.rb's WolfRPG boot class draws the map with RGSS::Bitmap/Sprite/
  # Viewport and reads input through RGSS::Input -- the shared engine
  # namespace every maker gem draws its rendering primitives from.
  add_dependency 'mruby-rgss'

  # Load order matters: wolf.rb defines the Wolf module, its byte-level Reader,
  # LZ4 decoder and Wolf.bin/utf8 helpers that data.rb's per-file classes (and
  # their MAGIC/TERMINATOR constants, evaluated at class-body time) depend on;
  # runtime.rb's WolfRPG boot class depends on both plus mruby-rgss's shared
  # RGSS namespace. Set the order explicitly rather than relying on the
  # default alphabetical glob (see mruby-rpgvx/mrbgem.rake for the same need).
  spec.rbfiles = %w[wolf data runtime].map { |name| "#{dir}/mrblib/#{name}.rb" }
end
