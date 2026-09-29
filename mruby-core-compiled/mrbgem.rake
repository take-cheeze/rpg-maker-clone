require 'shellwords'
require_relative '../tools/bc2cpp/compiled_gems'

# Opt-in AOT-compiled C++ replacements for the methods of mruby's own Ruby that
# tools/bc2cpp/core_methods.rb lets compile (docs/adr/0264): the block-free
# methods of core mrblib, the core gems' mrblib and mruby-stringio/onig-regexp.
# Registration is generated (bc2cpp_register_owner_methods), so there is no
# hand-kept register list to drift.
#
# Only exists in the build when RPGMAKER_BC2CPP is set (build_config.rb).
MRuby::Gem::Specification.new('mruby-core-compiled') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'Opt-in AOT-compiled C++ replacements for listed mruby core mrblib methods'

  # Every gem whose bytecode this registers over must have run its init first,
  # or its mrblib would replace the compiled body: the engine gems (which
  # reopen Array and StringIO), and each core gem BC2CPP_CORE_MRBLIB_GEMS names.
  # mruby-dir and the Onigmo gem are not in every build, so they only count
  # where build_config.rb added them.
  #
  # The dependency on mruby-rpg2k is deliberate: build_config.rb's gem dispatch
  # initialises a gem that depends on a maker directly right after that maker,
  # so the compiled core is registered only for an RPG2000/2003 run. The other
  # makers run game scripts whose blocks yield Fibers through core iterators
  # (docs/adr/0023). The Fiber guard of ADR 0269 makes the compiled iterators hand
  # those calls to the bytecode, but no maker but RPG2000/2003 has been run with it.
  # The compiled bodies themselves are always linked, so compiled engine code
  # can still call them directly.
  %w[mruby-lcf mruby-rgss mruby-rpg2k].each { |gem_name| add_dependency gem_name }
  (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
    next if %w[mruby-dir mruby-onig-regexp].include?(gem_name) && spec.build.gems.none? { |g| g.name == gem_name }

    add_dependency gem_name
  end
  extend Bc2cppClosedWorldOption
  extend Bc2cppHotOnlyOption

  bc2cpp = "#{dir}/../tools/bc2cpp/bc2cpp.rb"
  # Every tools/bc2cpp/*.rb, globbed: bc2cpp.rb require_relative's its siblings, and
  # a sibling edit must invalidate the generated file (see mruby-rgss-compiled).
  bc2cpp_tool_srcs = Dir["#{dir}/../tools/bc2cpp/*.rb"]
  compiled_gems_rb = "#{dir}/../tools/bc2cpp/compiled_gems.rb"
  # The same closed world every compiled gem reads: the core files first, then
  # mruby-rpg2k/lcf/rgss (compiled_gems.rb closed_world_mrblib_srcs).
  closed_world_prereqs = bc2cpp_closed_world_prerequisites("#{dir}/..")
  native_srcs = Dir["#{dir}/../mruby-rgss/src/*.cxx"] + core_native_srcs("#{dir}/../3rd/mruby") +
                external_gem_native_srcs("#{dir}/..")
  foreign_ruby_srcs = foreign_mrblib_srcs("#{dir}/..")

  this_gem = BC2CPP_COMPILED_GEMS.fetch('mruby-core-compiled')
  other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == 'mruby-core-compiled' }
  target_owners = this_gem[:owners]
  other_owners = other_gems.values.flat_map { |g| g[:owners] }
  other_decls_headers = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_decls.h" }
  other_generated = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_gen.cpp" }

  generated = "#{build_dir}/core_compiled_gen.cpp"

  # bc2cpp.rb runs MRBC: without this edge `rake -m` can start codegen before
  # the bootstrap mrbc exists (ADR 0228).
  file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, spec.build.mrbcfile, *closed_world_prereqs, *native_srcs,
                     *foreign_ruby_srcs, *bc2cpp_host_native_srcs(build.name, "#{dir}/.."),
                     BC2CPP_HOT_METHODS_PATH, BC2CPP_CORE_REFUSED_PATH] do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    env = {
      'MRBC' => spec.build.mrbcfile.to_s,
      'OUT_SYMBOL' => 'core_compiled',
      'OUT_DIR' => build_dir,
      'ONLY_OWNERS' => target_owners.join(','),
      'OTHER_OWNERS' => other_owners.join(','),
      'OTHER_DECLS_HEADER' => Shellwords.join(other_decls_headers),
      'NATIVE_SRCS' => Shellwords.join(native_srcs),
      'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_ruby_srcs),
      'SKIP_UNSUPPORTED' => '1',
    }.merge(bc2cpp_closed_world_env(spec, "#{dir}/..")).merge(bc2cpp_hot_only_env(spec))
    closed_world_srcs = bc2cpp_closed_world_srcs(spec, "#{dir}/..")
    cmd = "#{RbConfig.ruby.shellescape} #{bc2cpp.shellescape} " \
          "#{closed_world_srcs.map(&:shellescape).join(' ')} > #{generated.shellescape}"
    sh env, cmd
  end

  # register.cxx #includes the generated file, which #includes the other compiled
  # gems' *_decls.h, so it waits on their codegen (not the reverse: that would be
  # a cycle).
  file "#{dir}/src/register.cxx" => [generated, *other_generated]
  cxx.include_paths << build_dir
  # include/rgss_construct.hxx for bc2cpp's own emitted NATIVE_CONSTRUCT_TARGETS decls.
  cxx.include_paths << "#{dir}/../include"
end
