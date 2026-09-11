require 'shellwords'
require_relative '../tools/bc2cpp/compiled_gems'

# Opt-in AOT-compiled C++ replacements for all 17 of RGSS::Sprite's own
# real bytecode-defined accessor methods (docs/adr/0139) -- the plain
# Ruby readers mruby-rgss/mrblib/lib.rb reopens the native Sprite class
# with (`x`/`y`/`opacity`/`zoom_x`/`zoom_y`/`tone`/`color`/`src_rect`/...),
# generated at build time by tools/bc2cpp/bc2cpp.rb. Sprite's own writers
# (`x=`/`y=`/...) and #initialize are native C++ (mruby-rgss/src/lib.cxx),
# invisible to bc2cpp the same way every other native method in that file
# is -- nothing to compile or override for those.
#
# This whole gem only exists in the build when RPGMAKER_BC2CPP is set (see
# build_config.rb) -- it is never part of the default desktop or wio build.
MRuby::Gem::Specification.new('mruby-rgss-compiled') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'Opt-in AOT-compiled C++ replacements for RGSS::Sprite bytecode methods'

  add_dependency 'mruby-rgss'

  bc2cpp = "#{dir}/../tools/bc2cpp/bc2cpp.rb"
  # BC2CPP_COMPILED_GEMS' own owners list (target_owners below) comes from
  # this file, required above -- it has to be a real prerequisite of the
  # `generated` rule too, or Rake has no way to know a changed owners list
  # alone should invalidate an already-built generated file. See
  # mruby-rpg2k-compiled/mrbgem.rake's own comment for the real bug this
  # caught.
  compiled_gems_rb = "#{dir}/../tools/bc2cpp/compiled_gems.rb"
  # Whole-program closed-world source set -- same reasoning as
  # mruby-lcf-compiled/mrbgem.rake's own comment: bc2cpp's MONO/POLY
  # devirtualization decisions need to see every gem that could define a
  # colliding method name, not just mruby-rgss's own mrblib, even though
  # ONLY_OWNERS below narrows what actually gets *emitted* to RGSS::Sprite
  # alone.
  closed_world_srcs = Dir["#{dir}/../mruby-rpg2k/mrblib/**/*.rb"] +
                       Dir["#{dir}/../mruby-lcf/mrblib/*.rb"] +
                       Dir["#{dir}/../mruby-rgss/mrblib/*.rb"]

  # RGSS's own C++-implemented methods are invisible to closed_world_srcs
  # above (no .rb source for them) -- see mruby-lcf-compiled/mrbgem.rake's
  # own comment on NATIVE_SRCS for why that makes bc2cpp's MONO/POLY
  # registry unsound wherever a native method collides by bare name with a
  # bytecode-defined one, and why closing it only needs the flat name set.
  # mruby's own core is the same gap against the standard library instead
  # of RGSS -- see compiled_gems.rb's own core_native_srcs comment.
  native_srcs = Dir["#{dir}/../mruby-rgss/src/*.cxx"] + core_native_srcs("#{dir}/../3rd/mruby")

  this_gem = BC2CPP_COMPILED_GEMS.fetch('mruby-rgss-compiled')
  other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == 'mruby-rgss-compiled' }
  target_owners = this_gem[:owners]
  # See mruby-lcf-compiled/mrbgem.rake's own comment on OTHER_OWNERS/
  # OTHER_DECLS_HEADER -- cross-gem devirtualization, the other half of
  # this same mechanism.
  other_owners = other_gems.values.flat_map { |g| g[:owners] }
  other_decls_headers = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_decls.h" }
  other_generated = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_gen.cpp" }

  generated = "#{build_dir}/rgss_compiled_gen.cpp"

  file generated => [bc2cpp, compiled_gems_rb, *closed_world_srcs, *native_srcs] do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    env = {
      'MRBC' => spec.build.mrbcfile.to_s,
      'OUT_SYMBOL' => 'rgss_compiled',
      'OUT_DIR' => build_dir,
      'ONLY_OWNERS' => target_owners.join(','),
      'OTHER_OWNERS' => other_owners.join(','),
      'OTHER_DECLS_HEADER' => Shellwords.join(other_decls_headers),
      'NATIVE_SRCS' => Shellwords.join(native_srcs),
      'SKIP_UNSUPPORTED' => '1',
    }
    cmd = "#{RbConfig.ruby.shellescape} #{bc2cpp.shellescape} " \
          "#{closed_world_srcs.map(&:shellescape).join(' ')} > #{generated.shellescape}"
    sh env, cmd
  end

  # register.cxx #includes the generated file directly, mirroring the
  # other two compiled gems' own src/register.cxx one directory over --
  # also depends on every other compiled gem's own generated file for the
  # same reason (its #include of their *_decls.h needs that file to exist
  # by the time this translation unit is compiled). Depending on
  # `generated` itself (not on `other_generated` here) keeps this a DAG,
  # not a cycle: neither gem's own codegen step waits on the other's.
  file "#{dir}/src/register.cxx" => [generated, *other_generated]
  cxx.include_paths << build_dir
end
