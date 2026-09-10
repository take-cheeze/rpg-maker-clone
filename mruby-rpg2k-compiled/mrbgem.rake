require 'shellwords'

# Opt-in AOT-compiled C++ replacements for Game::Picture's own bytecode
# methods (docs/adr/0139's own follow-up) -- 25 of its 26 real methods
# (everything but #initialize, which takes optional arguments bc2cpp's
# calling convention doesn't model), generated at build time by
# tools/bc2cpp/bc2cpp.rb, mruby's bytecode compiler still handles
# #initialize itself (and anything else this gem doesn't override).
#
# This whole gem only exists in the build when RPGMAKER_BC2CPP is set (see
# build_config.rb) -- it is never part of the default desktop or wio build.
MRuby::Gem::Specification.new('mruby-rpg2k-compiled') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'Opt-in AOT-compiled C++ replacements for Game::Picture bytecode methods'

  add_dependency 'mruby-rpg2k'

  bc2cpp = "#{dir}/../tools/bc2cpp/bc2cpp.rb"
  # Whole-program closed-world source set -- same reasoning as
  # mruby-lcf-compiled/mrbgem.rake's own comment: bc2cpp's MONO/POLY
  # devirtualization decisions need to see every gem that could define a
  # colliding method name, not just mruby-rpg2k's own mrblib, even though
  # ONLY_OWNERS below narrows what actually gets *emitted* to Game::Picture
  # alone.
  closed_world_srcs = Dir["#{dir}/../mruby-rpg2k/mrblib/**/*.rb"] +
                       Dir["#{dir}/../mruby-lcf/mrblib/*.rb"] +
                       Dir["#{dir}/../mruby-rgss/mrblib/*.rb"]

  # RGSS's own C++-implemented methods are invisible to closed_world_srcs
  # above (no .rb source for them) -- see mruby-lcf-compiled/mrbgem.rake's
  # own comment on NATIVE_SRCS for why that makes bc2cpp's MONO/POLY
  # registry unsound wherever a native method collides by bare name with a
  # bytecode-defined one, and why closing it only needs the flat name set.
  native_srcs = Dir["#{dir}/../mruby-rgss/src/*.cxx"]

  target_owners = %w[Game::Picture]

  generated = "#{build_dir}/rpg2k_compiled_gen.cpp"

  file generated => [bc2cpp, *closed_world_srcs, *native_srcs] do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    env = {
      'MRBC' => spec.build.mrbcfile.to_s,
      'OUT_SYMBOL' => 'rpg2k_compiled',
      'OUT_DIR' => build_dir,
      'ONLY_OWNERS' => target_owners.join(','),
      'NATIVE_SRCS' => Shellwords.join(native_srcs),
      'SKIP_UNSUPPORTED' => '1',
    }
    cmd = "#{RbConfig.ruby.shellescape} #{bc2cpp.shellescape} " \
          "#{closed_world_srcs.map(&:shellescape).join(' ')} > #{generated.shellescape}"
    sh env, cmd
  end

  # register.cxx #includes the generated file directly, mirroring
  # mruby-lcf-compiled's own src/register.cxx one gem over.
  file "#{dir}/src/register.cxx" => generated
  cxx.include_paths << build_dir
end
