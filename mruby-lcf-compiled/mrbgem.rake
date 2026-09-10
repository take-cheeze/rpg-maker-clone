require 'shellwords'

# Opt-in AOT-compiled C++ replacements for a hand-picked, provably-safe
# subset of LCF::File/Database/MapTree/MapUnit/SaveData's own bytecode
# methods (docs/adr/0139) -- header/schema/terminate_root?/rpg2003?/maker/
# key?/to_lcf, generated at build time by tools/bc2cpp/bc2cpp.rb, mruby's
# bytecode compiler still handles everything else this gem doesn't
# override (#initialize, #[], #[]=, #method_missing, #respond_to_missing?,
# #save_to -- see bc2cpp's own SKIP_UNSUPPORTED output for exactly why each
# one stays interpreted).
#
# This whole gem only exists in the build when RPGMAKER_BC2CPP is set (see
# build_config.rb) -- it is never part of the default desktop or wio build.
# Disabled, its one visible effect is that this directory exists on disk;
# nothing in the default build tree references it.
MRuby::Gem::Specification.new('mruby-lcf-compiled') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'Opt-in AOT-compiled C++ replacements for select LCF::File-family bytecode methods'

  add_dependency 'mruby-lcf'

  bc2cpp = "#{dir}/../tools/bc2cpp/bc2cpp.rb"
  lcf_mrblib = "#{dir}/../mruby-lcf/mrblib"
  # The whole-program closed-world source set this run's registry is built
  # from -- NOT just mruby-lcf's own mrblib. Confirmed a real, load-bearing
  # distinction while first wiring this up (docs/adr/0139): analyzed alone,
  # LCF::Database#rpg2003? looks like the only :rpg2003? definition
  # anywhere, but the real game also defines Game::Actor/Party/Battle
  # #rpg2003? -- 4 definitions, genuinely polymorphic. Feeding the whole
  # rpg2k+lcf+rgss mrblib set in (the same three gems build_config.rb
  # always loads together) is what lets bc2cpp's own MONO/POLY resolution
  # come out correct; ONLY_OWNERS below then narrows what actually gets
  # *emitted* to just the LCF file classes, independently.
  closed_world_srcs = Dir["#{dir}/../mruby-rpg2k/mrblib/**/*.rb"] +
                       Dir["#{lcf_mrblib}/*.rb"] +
                       Dir["#{dir}/../mruby-rgss/mrblib/*.rb"]

  # RGSS's own C++-implemented methods (Sprite/Bitmap/Viewport/Window/Rect/
  # ...) are invisible to the closed_world_srcs scan above -- there's no .rb
  # source for them, so bc2cpp's own MONO/POLY registry never sees them at
  # all. A method name real bytecode defines exactly once still looks MONO
  # even when a *different* class registers a same-named method natively --
  # dispatch is by name only, so that's unsound wherever it happens (found
  # 6 real collisions running this against mruby-rgss/src/lib.cxx: :x/:y/
  # :width/:height/:ox/:oy, RGSS::Sprite's own bytecode readers vs.
  # RGSS::Rect/Viewport's natively-registered same-named accessors). Feeding
  # every mruby-rgss/src/*.cxx file's mrb_define_method-family call sites in
  # via NATIVE_SRCS closes that gap -- see bc2cpp.rb's own comment on
  # extract_native_method_names for why this only ever needs the flat set of
  # names, never an owner class or a callable C++ symbol.
  native_srcs = Dir["#{dir}/../mruby-rgss/src/*.cxx"]

  target_owners = %w[LCF::File LCF::Database LCF::MapTree LCF::MapUnit LCF::SaveData]

  generated = "#{build_dir}/lcf_compiled_gen.cpp"

  file generated => [bc2cpp, *closed_world_srcs, *native_srcs] do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    env = {
      'MRBC' => spec.build.mrbcfile.to_s,
      'OUT_SYMBOL' => 'lcf_compiled',
      'OUT_DIR' => build_dir,
      'ONLY_OWNERS' => target_owners.join(','),
      'NATIVE_SRCS' => Shellwords.join(native_srcs),
      # See bc2cpp.rb's own comment: a `#error` this C++ toolchain actually
      # compiles halts the whole build. Any LCF::File-family method bc2cpp
      # can't safely compile is simply never emitted here -- it keeps
      # running on the ordinary interpreted bytecode path, which mruby-lcf
      # (this gem's own dependency) already loads first.
      'SKIP_UNSUPPORTED' => '1',
    }
    cmd = "#{RbConfig.ruby.shellescape} #{bc2cpp.shellescape} " \
          "#{closed_world_srcs.map(&:shellescape).join(' ')} > #{generated.shellescape}"
    sh env, cmd
  end

  # register.cxx #includes the generated file directly (its own functions
  # are all `static`, same shape as bc2cpp's own toy harness) -- so it's
  # the only real translation unit, auto-discovered from src/ like any
  # other mrbgem source; this `file` dependency just forces codegen to run
  # before it's compiled, mirroring mruby-lcf's own lcf.cxx => cp932.h
  # pattern one directory over.
  file "#{dir}/src/register.cxx" => generated
  cxx.include_paths << build_dir
end
