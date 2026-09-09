MRuby::Gem::Specification.new('mruby-lcf') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'LCF data loader'

  add_dependency 'mruby-io'
  add_dependency 'mruby-pack'
  add_dependency 'mruby-string-ext'

  add_test_dependency 'mruby-stringio'

  cxx.include_paths << "#{dir}/../3rd/uni-algo/include"
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/uni-algo"
  linker.libraries << "uni-algo"

  cxx.include_paths << build_dir

  objs << objfile("#{build_dir}/cp932")

  file "#{dir}/src/lcf.cxx" => "#{build_dir}/cp932.h"
  file "#{build_dir}/cp932.h" => "#{build_dir}/cp932.cc"
  file "#{build_dir}/cp932.cc" => "#{dir}/cp932_to_unicode.rb" do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    Dir.chdir build_dir do
      ruby  t.prereqs.first
    end
  end

  # docs/adr/0109: mrblib/schema.rb's ~1,150 field descriptors, each its own
  # Hash-literal-construction bytecode sequence, measured at 45,293 bytes
  # (real `mrbc -g`) -- the single largest file in this gem. Replaced here
  # with a compact packed binary blob plus a small, constant-size decoder
  # (gen_schema_blob.rb), verified byte-for-byte behaviorally identical
  # (every constant, every nested/lazy field, every default, the two
  # object-identity-sharing cases) against schema.rb by that ADR's own
  # comparison script -- 23,878 bytes, a real 47% cut. ADR 109 only ever
  # measured this against wio's own flash budget (15,624 bytes recovered on
  # a real `env:wio_rgss_boot` relink); no other target is flash-constrained
  # enough to need it.
  #
  # wio-only (docs/adr/0123): this swap used to apply to *every* build,
  # including the native "host" config `rake test` uses. That combined the
  # blob's runtime decoder with mrbtest's full 27-gem load (every maker gem
  # plus every test dependency at once, unlike any real shipped target,
  # which loads at most one maker) -- under exactly that combination,
  # `LCF::Schema::DATABASE`/`MAP_TREE`/`MAP_UNIT`/`SAVE_DATA`/`SAVE_MOVABLE`/
  # `SAVE_PARTY_ACTOR` (and only those six of the module's 27 top-level
  # constants) came up `uninitialized constant` in mruby-lcf's own test
  # suite, 28 crashes, even though each one had just been assigned
  # correctly by this exact same schema_blob.rb moments earlier (confirmed
  # by printing the freshly-assigned constant's class right after the
  # assignment statement that sets it). Toggling *only* this swap off (host
  # build, otherwise identical) reproduced `Crash: 0`; toggling it back on
  # reproduced `Crash: 28` -- deterministic and 100% attributable to the
  # blob mechanism itself, not to gem load order, GC (an explicit
  # `GC.disable` before the blob loads made no difference), or an inline-
  # cache staleness on the `::` constant-access opcode (`Module#const_get`
  # failed identically to the `LCF::Schema::DATABASE` syntax, and
  # `const_defined?` -- no inline cache at all -- agreed the entry was
  # simply gone). No root cause narrower than "the decoder's runtime output
  # under mrbtest's specific full-gem scale" was found; every real shipped
  # target (single maker gem, confirmed via `exe_open`/`render_probe`/
  # `audio_probe`/`error_dump`, which exercise the real desktop binary
  # against real Nepheshel game data) was never affected.
  #
  # Scoping the swap to wio -- the only target this ADR's own numbers ever
  # justified it for -- sidesteps the bug entirely rather than chasing it
  # further: wio is cross-compiled and never runs through `rake test` (the
  # host build only exists there to produce `mrbc`), so the one target that
  # keeps the blob is also the one target that was never going to exercise
  # this failure mode. Every other target (host/desktop, wasm, psp,
  # android) goes back to `schema.rb`'s plain Hash literals -- the same
  # form the CRuby `scripts/*_check.rb` scripts already trust, and the one
  # this ADR's own comparison script verified against byte-for-byte.
  #
  # schema.rb itself is untouched and stays the single source of truth
  # (every scripts/*_check.rb script `load`s it directly under CRuby, with
  # no dependency on this generator or its output); only wio's own build
  # copy is swapped for the generated one.
  if spec.build.name == 'wio'
    spec.rbfiles -= ["#{dir}/mrblib/schema.rb"]
    spec.rbfiles << "#{build_dir}/schema_blob.rb"
    file "#{build_dir}/schema_blob.rb" => ["#{dir}/gen_schema_blob.rb", "#{dir}/mrblib/schema.rb", "#{dir}/mrblib/lcf.rb"] do |t|
      FileUtils.mkdir_p build_dir, verbose: true
      ruby t.prereqs.first, "#{dir}/mrblib/schema.rb", "#{build_dir}/schema_blob.rb"
    end
  end

  wio_strip_debug_rbfiles(spec)
end
