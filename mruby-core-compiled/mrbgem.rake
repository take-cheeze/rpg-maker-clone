require 'shellwords'
require_relative '../tools/bc2cpp/compiled_gems'

# Opt-in AOT-compiled C++ replacements for the methods of mruby's own Ruby that
# tools/bc2cpp/core_methods.rb lets compile: the block-free
# methods of core mrblib, the core gems' mrblib and mruby-stringio/onig-regexp.
# Registration is generated (bc2cpp_register_owner_methods), so there is no
# hand-kept register list to drift.
#
# Only exists in the build when RPGMAKER_BC2CPP is set on a closed-world build
MRuby::Gem::Specification.new('mruby-core-compiled') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'Opt-in AOT-compiled C++ replacements for listed mruby core mrblib methods'

  # Every gem whose bytecode this registers over must have run its init first,
  # or its mrblib would replace the compiled body: the engine gems (which
  # reopen Array and StringIO), and each core gem BC2CPP_CORE_MRBLIB_GEMS names.
  # Struct, Dir and the Onigmo gem are not in every build, so they only count
  # where build_config.rb added them.
  #
  # The dependency on mruby-rpg2k is deliberate: build_config.rb's gem dispatch
  # initialises a gem that depends on a maker directly right after that maker,
  # so the compiled core is registered only for an RPG2000/2003 run. The other
  # makers run game scripts whose blocks yield Fibers through core iterators
  # A Fiber guard makes the compiled iterators hand
  # those calls to the bytecode, but no maker but RPG2000/2003 has been run with it.
  # The compiled bodies themselves are always linked, so compiled engine code
  # can still call them directly.
  %w[mruby-lcf mruby-rgss mruby-rpg2k].each { |gem_name| add_dependency gem_name }
  (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
    next if %w[mruby-dir mruby-onig-regexp mruby-struct].include?(gem_name) && spec.build.gems.none? { |g| g.name == gem_name }

    add_dependency gem_name
  end

  # Every tools/bc2cpp/*.rb, globbed: bc2cpp.rb require_relative's its siblings, and
  # a sibling edit must invalidate the generated file (see mruby-rgss-compiled).
  bc2cpp_tool_srcs = Dir["#{dir}/../tools/bc2cpp/*.rb"]
  compiled_gems_rb = "#{dir}/../tools/bc2cpp/compiled_gems.rb"
  # The gem table itself (owners source, OUT_SYMBOL) is data in this file; editing it must regenerate too.
  compiled_gems_yml = "#{dir}/../tools/bc2cpp/compiled_gems.yml"
  # The same closed world every compiled gem reads: the core files first, then
  # mruby-rpg2k/lcf/rgss (compiled_gems.rb closed_world_mrblib_srcs).
  closed_world_prereqs = bc2cpp_closed_world_prerequisites("#{dir}/..")
  native_srcs = bc2cpp_rgss_native_srcs("#{dir}/..", build.name) + core_native_srcs("#{dir}/../3rd/mruby") +
                external_gem_native_srcs("#{dir}/..")
  foreign_ruby_srcs = foreign_mrblib_srcs("#{dir}/..")

  other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == 'mruby-core-compiled' }
  other_generated = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_gen.cpp" }

  generated = "#{build_dir}/core_compiled_gen.cpp"

  # bc2cpp.rb runs MRBC: without this edge `rake -m` can start codegen before
  # the bootstrap mrbc exists.
  file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, compiled_gems_yml, spec.build.mrbcfile, *closed_world_prereqs, *native_srcs,
                     *foreign_ruby_srcs, *bc2cpp_host_native_srcs(build.name, "#{dir}/.."),
                     BC2CPP_CORE_REFUSED_PATH] do |t|
    # SHARED_GENERATION: with every other compiled gem of this build that is out of date, in one
    # bc2cpp.rb analysis (tools/bc2cpp/compiled_gems.rb bc2cpp_compiled_gem_job holds this gem's environment).
    Bc2cppCompiledGemGeneration.generate(spec, "#{dir}/..")
  end

  # register.cxx #includes the generated file, which #includes the other compiled
  # gems' *_decls.h, so it waits on their codegen (not the reverse: that would be
  # a cycle).
  file "#{dir}/src/register.cxx" => [generated, *other_generated]
  # BC2CPP_SHARDS (docs/bc2cpp-shards.md): the rest of the generated code, compiled beside register.cxx.
  bc2cpp_compiled_gem_shards(spec, generated, other_generated)
  cxx.include_paths << build_dir
  cxx.defines << 'BC2CPP_FAIL_FAST_TYPE' if BC2CPP_FAIL_FAST_TYPE
  # include/rgss_construct.hxx for bc2cpp's own emitted NATIVE_CONSTRUCT_TARGETS decls.
  cxx.include_paths << "#{dir}/../include"
end
