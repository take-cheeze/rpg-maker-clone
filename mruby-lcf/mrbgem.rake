MRuby::Gem::Specification.new('mruby-lcf') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'LCF data loader'

  add_dependency 'mruby-io'
  add_dependency 'mruby-pack'

  add_test_dependency 'mruby-stringio'

  cxx.include_paths << "#{dir}/../3rd/uni-algo/include"
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/uni-algo"
  linker.libraries << "uni-algo"

  cxx.include_paths << build_dir

  objs << objfile("#{build_dir}/cp932")

  file "#{dir}/src/lcf.cxx" => "#{build_dir}/cp932.h"
  file "#{build_dir}/cp932.h" => "#{build_dir}/cp932.cc"
  file "#{build_dir}/cp932.cc" => "#{dir}/cp932_to_unicode.rb" do
    FileUtils.mkdir_p build_dir, verbose: true
    p ENV["cp932_table"]
    Dir.chdir build_dir do
      sh "#{dir}/cp932_to_unicode.rb"
    end
  end
end
