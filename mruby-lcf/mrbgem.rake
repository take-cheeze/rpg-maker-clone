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
  # comparison script -- 23,878 bytes, a real 47% cut.
  #
  # schema.rb itself is untouched and stays the single source of truth
  # (every scripts/*_check.rb script `load`s it directly under CRuby, with
  # no dependency on this generator or its output); only the *mruby build's
  # own copy* is swapped for the generated one.
  spec.rbfiles -= ["#{dir}/mrblib/schema.rb"]
  spec.rbfiles << "#{build_dir}/schema_blob.rb"
  file "#{build_dir}/schema_blob.rb" => ["#{dir}/gen_schema_blob.rb", "#{dir}/mrblib/schema.rb", "#{dir}/mrblib/lcf.rb"] do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    ruby t.prereqs.first, "#{dir}/mrblib/schema.rb", "#{build_dir}/schema_blob.rb"
  end
end
