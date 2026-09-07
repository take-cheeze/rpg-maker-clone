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
  # data_wolf.rb's Wolf::DataWolf wraps a plain byte String in a StringIO
  # (mirroring RPGXP::RGSSAD's own .new, mruby-rpgxp/mrblib/rgssad.rb) so a
  # test or a caller with the archive already in memory does not need a real
  # file -- only .open does, via mruby-io above.
  add_dependency 'mruby-stringio'
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
  # interpreter.rb runs each live Common Event as its own Fiber (mirroring
  # mruby-rpgxp's ScriptHost driver, ADR 0023) so a Wait command can suspend
  # just that event without blocking the frame loop or any other event.
  add_dependency 'mruby-fiber'
  # save_data.rb's own Wolf::SaveData.write/.read (SaveVariable(222)/
  # LoadVariable(221)) needs Dir.mkdir/.exist? and Marshal.dump/.load; both
  # are in build_config.rb's own shared gem list already, but declared here
  # too for the same reason mruby-sprintf already is above -- so the per-gem
  # `rake test` binary has them.
  add_dependency 'mruby-dir'
  add_dependency 'mruby-marshal'
  # save_data.rb's own Array#none? (the forbidden-path-token check).
  add_dependency 'mruby-enum-ext'

  # Load order matters: wolf.rb defines the Wolf module, its byte-level Reader,
  # LZ4 decoder and Wolf.bin/utf8 helpers that data_wolf.rb and data.rb's
  # per-file classes (and their MAGIC/TERMINATOR constants, evaluated at
  # class-body time) depend on; data_wolf.rb's Wolf::DataWolf (the Data.wolf
  # packed-release reader) only needs wolf.rb's Wolf::Error, but must load
  # before data.rb since Wolf::Project#initialize calls DataWolf.find/.open;
  # vars.rb's ValueRef/VarStore need Wolf::Error; save_data.rb's Wolf::SaveData
  # runs against vars.rb's VarStore#string_ref?; interpreter.rb runs against
  # data.rb's Command/CommonEvent classes and vars.rb's VarStore (and, for
  # SaveVariable/LoadVariable, save_data.rb's Wolf::SaveData); runtime.rb's
  # WolfRPG boot class depends on all of the above plus mruby-rgss's shared
  # RGSS namespace. Set the order explicitly rather than relying on the
  # default alphabetical glob (see mruby-rpgvx/mrbgem.rake for the same need).
  spec.rbfiles = %w[wolf data_wolf data vars save_data interpreter runtime].map { |name| "#{dir}/mrblib/#{name}.rb" }
end
