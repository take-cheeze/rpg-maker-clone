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

  # docs/adr/0144: mruby-rgss/mrbgem.rake was, until this round, the ONLY
  # caller of wio_strip_bc2cpp_stubs; this round wires mruby-lcf up too,
  # alongside mruby-rpg2k's own first round (see that gem's own mrbgem.rake
  # for the shared methodology writeup). Unlike rpg2k, mruby-lcf-compiled's
  # own full `owners:` list (tools/bc2cpp/compiled_gems.rb) is already small
  # -- 12 owners, 34 real bc2cpp-registered methods total -- so this strips
  # ALL of them in one round rather than a bounded subset:
  #   LCF::File LCF::Database LCF::MapTree LCF::MapUnit LCF::SaveData
  #   LCF::MoveCommand LCF::EventCommand LCF::Tree LCF::Sections
  #   LCF::Array1D LCF::Array2D StringIO
  # (ground truth from a real wio_registered_methods.rb run, never
  # hand-counted): File 6 (`[]`/`[]=`/`key?`/`schema`/`header`/
  # `terminate_root?`), Database 4 (`rpg2003?`/`schema`/`header`/`maker`),
  # MapTree 2, MapUnit 3, SaveData 2 (each just `schema`/`header`, MapUnit
  # also `terminate_root?`) -- all five defined in mrblib/lcf_file.rb, not
  # lcf.rb; MoveCommand 1 (`initialize`), EventCommand 2 (`initialize`/
  # `param`), Tree 1 (`initialize`), Sections 4 (`initialize`/`[]`/`key?`/
  # `add`), Array1D 5 (`[]`/`[]=`/`key?`/`int16_values`/`delete`), Array2D 2
  # (`[]`/`[]=`), StringIO 1 (`ungetbyte`, this project's own real reopening
  # of mruby-stringio's `StringIO` -- see compiled_gems.rb's own round-31
  # comment) -- all seven defined in lcf.rb.
  #
  # `LCF::EventCommand#initialize`/`LCF::MoveCommand#initialize` are also
  # named in bc2cpp.rb's own NATIVE_ARG_TARGETS allowlist (their own
  # argument-passing codegen uses native, unboxed C++ types rather than
  # ordinary `mrb_value`s) -- checked directly against that constant, not
  # assumed absent; this only changes the *installed override's* own C++
  # calling convention, never when the base gem's own mrblib finishes
  # loading relative to when that override installs, so it has no bearing
  # on this mechanism's own soundness question and needed no different
  # treatment here. Neither owner is in DIRECT_CONSTRUCT_TARGETS, and no
  # owner here is `.singleton`-suffixed.
  #
  # Gem-init-ordering correctness: the exact same whole-native-closed-world
  # `mrb_funcall`/`mrb_funcall_argv`/`mrb_funcall_id`/`mrb_funcall_with_block`
  # grep mruby-rpg2k/mrbgem.rake's own comment documents (same file list,
  # same "register.cxx has zero real call sites outside comments describing
  # the *generated*, gem-init-independent runtime POLY fallback" result)
  # was checked against all 34 of these methods' own names too: zero real
  # matches. The one generic-sounding hit worth naming again here,
  # `mruby-stringio/src/stringio.c`'s own `mrb_funcall(..., "replace", ...)`
  # (a different method, `#replace`, not any of the 34 above) and
  # `mrb_funcall(..., "_sys_fail", ...)` calls, dispatch on a real `String`/
  # `StringIO` receiver, never any of these 12 owners.
  #
  # A second, LCF-specific soundness question rpg2k's own round surfaced
  # (see that gem's own comment on `Game::ChipSet`'s exclusion): whether any
  # of these 34 methods is also referenced by name at class-body-eval time
  # via `private :name`/`protected :name`/`public :name`/`alias_method` (a
  # real hazard -- deleting the `def` while such a companion statement
  # survives raises `NameError` at mrblib load, strictly before the
  # compiled override installs) or shadowed by an `attr_reader`/
  # `attr_accessor`/`attr_writer` of the same name. Checked directly with
  # the same real AST walk of every candidate owner's own class body in
  # both mrblib/lcf.rb and mrblib/lcf_file.rb: every `private`/`protected`
  # call found in either file is a bare, argument-less mode switch
  # (`LCF::Array1D`/`LCF::Array2D`, each just a plain `private` before their
  # own genuinely-internal helpers), and every `attr_reader` found
  # (`LCF::Tree#selected_id`/`#maps`, `LCF::EventCommand#code`/`#indent`/
  # `#string`/`#parameters`, `LCF::MoveCommand#command_id`/
  # `#parameter_string`/`#parameter_a`/`#parameter_b`/`#parameter_c`,
  # `LCF::Array1D#schema`) never collides with one of these 34 registered
  # names -- no `Game::ChipSet`-shaped exclusion needed here, so all 12
  # owners strip cleanly.
  #
  # Real, confirmed end to end: `strip_wio_bc2cpp_stubs.rb` (against a real
  # host `mrbc`'s own registry) rewrote both mrblib/lcf.rb and
  # mrblib/lcf_file.rb without raising, each rewrite still parses
  # (`RubyVM::AbstractSyntaxTree`/`ruby -c`), and loading the rewritten
  # pair under plain CRuby (after mrblib/schema.rb, for the `LCF::Schema::*`
  # constants a few of these methods reference) confirms every one of the
  # 34 stripped methods is gone (`method_defined?`/
  # `private_method_defined?` false, and for the four stripped
  # `#initialize`s, `instance_method(:initialize).owner` falls all the way
  # back to `BasicObject`) while every other real method on these classes
  # is untouched. Real measured size effect (host `mrbc -g`, matching this
  # build's own `enable_debug`): mrblib/lcf.rb 16,567 -> 13,868 bytes
  # (-2,699), mrblib/lcf_file.rb 3,431 -> 1,492 bytes (-1,939) -- 4,638
  # bytes total, before this gem's own wio_strip_debug_rbfiles pass runs.
  wio_strip_bc2cpp_stubs(spec, compiled_gem: 'mruby-lcf-compiled',
                         owners: %w[LCF::File LCF::Database LCF::MapTree LCF::MapUnit
                                    LCF::SaveData LCF::MoveCommand LCF::EventCommand LCF::Tree
                                    LCF::Sections LCF::Array1D LCF::Array2D StringIO])
  wio_strip_debug_rbfiles(spec)
end
