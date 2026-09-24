require 'shellwords'
require_relative '../tools/bc2cpp/compiled_gems'

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
  # build_config.rb turns on BC2CPP_CLOSED_WORLD for single-format builds.
  extend Bc2cppClosedWorldOption
  # build_config.rb turns on BC2CPP_HOT_ONLY (docs/adr/0214) for the same builds.
  extend Bc2cppHotOnlyOption

  bc2cpp = "#{dir}/../tools/bc2cpp/bc2cpp.rb"
  # STALE_REQUIRE_RELATIVE_DEPS: bc2cpp.rb require_relative's several sibling
  # files (native_expression_devirt.rb, symbol_cache.rb, const_site_cache.rb,
  # ...) that change its own generated output just as much as bc2cpp.rb itself
  # editing only one of THOSE never touched bc2cpp.rb's own mtime, so an
  # incremental build's `file generated => [bc2cpp, ...]` rule considered
  # `generated` already up to date and silently kept stale C++ -- the exact
  # same failure mode `compiled_gems_rb`'s own comment just below documents
  # for a changed owners list, one file over. Globbed, not hand-listed, for
  # the same "a future new file here is a prerequisite by construction, not
  # by someone remembering to add it" reason cmake/build-mruby.cmake's own
  # `file(GLOB bc2cpp_files CONFIGURE_DEPENDS ...)` already globs this exact
  # directory for the outer CMake-level rebuild trigger.
  bc2cpp_tool_srcs = Dir["#{dir}/../tools/bc2cpp/*.rb"]
  # BC2CPP_COMPILED_GEMS' own owners list (target_owners below) comes from
  # this file, required above -- it has to be a real prerequisite of the
  # `generated` rule too, or Rake has no way to know a changed owners list
  # (no bc2cpp.rb/closed_world_srcs/native_srcs edit at all) should
  # invalidate an already-built generated file: caught for real merging a
  # round of parallel coverage-expansion work into an already-built tree
  # (docs/adr/0139's own follow-up) -- `generated` was stale, silently
  # missing the round's own new owner, and g++ failed on an undeclared
  # `_impl` symbol only because register.cxx's own hand-written call site
  # for it happened to still be there.
  compiled_gems_rb = "#{dir}/../tools/bc2cpp/compiled_gems.rb"
  # Whole-program closed-world source set -- same reasoning as
  # mruby-lcf-compiled/mrbgem.rake's own comment: bc2cpp's MONO/POLY
  # devirtualization decisions need to see every gem that could define a
  # colliding method name, not just mruby-rpg2k's own mrblib, even though
  # ONLY_OWNERS below narrows what actually gets *emitted* to Game::Picture
  # alone. Computed by compiled_gems.rb's own closed_world_mrblib_srcs
  # (required above), the same one mruby-lcf-compiled's/
  # mruby-rgss-compiled's own mrbgem.rake calls too -- see that helper's
  # own comment for why this stopped being three separately hand-
  # maintained literals.
  closed_world_srcs = closed_world_mrblib_srcs("#{dir}/..")

  # RGSS's own C++-implemented methods are invisible to closed_world_srcs
  # above (no .rb source for them) -- see mruby-lcf-compiled/mrbgem.rake's
  # own comment on NATIVE_SRCS for why that makes bc2cpp's MONO/POLY
  # registry unsound wherever a native method collides by bare name with a
  # bytecode-defined one, and why closing it only needs the flat name set.
  # mruby's own core is the same gap against the standard library instead
  # of RGSS -- see compiled_gems.rb's own core_native_srcs comment.
  #
  # external_gem_native_srcs (compiled_gems.rb) closes the same gap one
  # level further out, for the three always-active gems (mruby-marshal/
  # mruby-onig-regexp/mruby-stringio) that live outside mruby_root
  # entirely -- see that helper's own comment.
  native_srcs = Dir["#{dir}/../mruby-rgss/src/*.cxx"] + core_native_srcs("#{dir}/../3rd/mruby") +
                external_gem_native_srcs("#{dir}/..")

  # INTEGER_CONSTANT_PROOF: the Ruby-side twin of native_srcs above --
  # every Ruby source compiled into this same VM but outside bc2cpp's own
  # closed world, scanned for constant-assignment names only. See
  # foreign_mrblib_srcs (compiled_gems.rb) and bc2cpp.rb's own
  # IntegerConstants header for the real Enumerable::NONE collision it
  # exists to poison.
  foreign_ruby_srcs = foreign_mrblib_srcs("#{dir}/..")

  this_gem = BC2CPP_COMPILED_GEMS.fetch('mruby-rpg2k-compiled')
  other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == 'mruby-rpg2k-compiled' }
  target_owners = this_gem[:owners]
  # See mruby-lcf-compiled/mrbgem.rake's own comment on OTHER_OWNERS/
  # OTHER_DECLS_HEADER -- cross-gem devirtualization, the other half of
  # this same mechanism.
  other_owners = other_gems.values.flat_map { |g| g[:owners] }
  other_decls_headers = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_decls.h" }
  other_generated = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_gen.cpp" }

  generated = "#{build_dir}/rpg2k_compiled_gen.cpp"

  # bc2cpp.rb runs MRBC: without this edge `rake -m` can start codegen before
  # the bootstrap mrbc exists (ADR 0228).
  file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, *closed_world_srcs, *native_srcs,
                     *foreign_ruby_srcs, *bc2cpp_host_native_srcs(build.name, "#{dir}/.."),
                     BC2CPP_HOT_METHODS_PATH, spec.build.mrbcfile] do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    env = {
      'MRBC' => spec.build.mrbcfile.to_s,
      'OUT_SYMBOL' => 'rpg2k_compiled',
      'OUT_DIR' => build_dir,
      'ONLY_OWNERS' => target_owners.join(','),
      'OTHER_OWNERS' => other_owners.join(','),
      'OTHER_DECLS_HEADER' => Shellwords.join(other_decls_headers),
      'NATIVE_SRCS' => Shellwords.join(native_srcs),
      'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_ruby_srcs),
      'SKIP_UNSUPPORTED' => '1',
    }.merge(bc2cpp_closed_world_env(spec, "#{dir}/..")).merge(bc2cpp_hot_only_env(spec))
    cmd ="#{RbConfig.ruby.shellescape} #{bc2cpp.shellescape} " \
          "#{closed_world_srcs.map(&:shellescape).join(' ')} > #{generated.shellescape}"
    sh env, cmd
  end

  # register.cxx #includes the generated file directly, mirroring
  # mruby-lcf-compiled's own src/register.cxx one gem over -- also depends
  # on every other compiled gem's own generated file for the same reason
  # (its #include of their *_decls.h needs that file to exist by compile
  # time; see the sibling file's own comment for why this stays a DAG).
  file "#{dir}/src/register.cxx" => [generated, *other_generated]
  cxx.include_paths << build_dir
  # include/rgss_construct.hxx for bc2cpp's own emitted
  # `#include "rgss_construct.hxx"` (NATIVE_CONSTRUCT_TARGETS decls) --
  # the same wiring mruby-mvjs already uses for rgss_bitmap.hxx.
  cxx.include_paths << "#{dir}/../include"
end
