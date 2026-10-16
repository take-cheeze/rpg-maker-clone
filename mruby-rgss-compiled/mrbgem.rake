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
# This whole gem only exists in the build when RPGMAKER_BC2CPP is set on a
# closed-world build (psp/wio/maix, see build_config.rb; docs/adr/0466) -- it is
# never part of the default build, and never of a desktop build.
MRuby::Gem::Specification.new('mruby-rgss-compiled') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'Opt-in AOT-compiled C++ replacements for RGSS::Sprite bytecode methods'

  add_dependency 'mruby-rgss'
  # build_config.rb turns on BC2CPP_HOT_ONLY (docs/adr/0214) for the same builds.
  extend Bc2cppHotOnlyOption

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
  # alone should invalidate an already-built generated file. See
  # mruby-rpg2k-compiled/mrbgem.rake's own comment for the real bug this
  # caught.
  compiled_gems_rb = "#{dir}/../tools/bc2cpp/compiled_gems.rb"
  # Whole-program closed-world source set -- same reasoning as
  # mruby-lcf-compiled/mrbgem.rake's own comment: bc2cpp's MONO/POLY
  # devirtualization decisions need to see every gem that could define a
  # colliding method name, not just mruby-rgss's own mrblib, even though
  # ONLY_OWNERS below narrows what actually gets *emitted* to RGSS::Sprite
  # alone. Computed by compiled_gems.rb's own closed_world_mrblib_srcs
  # (required above), the same one mruby-lcf-compiled's/
  # mruby-rpg2k-compiled's own mrbgem.rake calls too -- see that helper's
  # own comment for why this stopped being three separately hand-
  # maintained literals.
  closed_world_prereqs = bc2cpp_closed_world_prerequisites("#{dir}/..")

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
  native_srcs = bc2cpp_rgss_native_srcs("#{dir}/..", build.name) + core_native_srcs("#{dir}/../3rd/mruby") +
                external_gem_native_srcs("#{dir}/..")

  # INTEGER_CONSTANT_PROOF: the Ruby-side twin of native_srcs above --
  # every Ruby source compiled into this same VM but outside bc2cpp's own
  # closed world, scanned for constant-assignment names only. See
  # foreign_mrblib_srcs (compiled_gems.rb) and bc2cpp.rb's own
  # IntegerConstants header for the real Enumerable::NONE collision it
  # exists to poison.
  foreign_ruby_srcs = foreign_mrblib_srcs("#{dir}/..")

  other_gems = BC2CPP_COMPILED_GEMS.reject { |name, _| name == 'mruby-rgss-compiled' }
  # See mruby-lcf-compiled/mrbgem.rake's own comment on OTHER_OWNERS/
  # OTHER_DECLS_HEADER -- cross-gem devirtualization, the other half of
  # this same mechanism.
  other_generated = other_gems.map { |name, g| "#{spec.build.build_dir}/mrbgems/#{name}/#{g[:out_symbol]}_gen.cpp" }

  generated = "#{build_dir}/rgss_compiled_gen.cpp"

  # bc2cpp.rb runs MRBC: without this edge `rake -m` can start codegen before
  # the bootstrap mrbc exists (ADR 0228).
  file generated => [*bc2cpp_tool_srcs, compiled_gems_rb, spec.build.mrbcfile, *closed_world_prereqs, *native_srcs,
                     *foreign_ruby_srcs, *bc2cpp_host_native_srcs(build.name, "#{dir}/.."),
                     BC2CPP_HOT_METHODS_PATH, BC2CPP_CORE_REFUSED_PATH] do |t|
    # SHARED_GENERATION (ADR 0464): with every other compiled gem of this build that is out of date, in one
    # bc2cpp.rb analysis (tools/bc2cpp/compiled_gems.rb bc2cpp_compiled_gem_job holds this gem's environment).
    Bc2cppCompiledGemGeneration.generate(spec, "#{dir}/..")
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
  # include/rgss_construct.hxx for bc2cpp's own emitted
  # `#include "rgss_construct.hxx"` (NATIVE_CONSTRUCT_TARGETS decls) --
  # the same wiring mruby-mvjs already uses for rgss_bitmap.hxx.
  cxx.include_paths << "#{dir}/../include"
end
