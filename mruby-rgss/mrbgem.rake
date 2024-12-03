MRuby::Gem::Specification.new('mruby-rgss') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RGSS implementation in mruby'

  cxx.include_paths <<
    "#{dir}/../3rd/uni-algo/include" <<
    "#{dir}/../3rd/lvgl" <<
    "#{dir}/../include" <<
    "#{dir}/../3rd/stb"
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/uni-algo" << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/lvgl/lib"
  linker.libraries << "uni-algo" << "lvgl"

  objs << objfile("#{build_dir}/shinonome")

  file "#{dir}/src/lib.cxx" => "#{build_dir}/shinonome.hxx"
  file "#{build_dir}/shinonome.hxx" => "#{build_dir}/shinonome.cxx"
  file "#{build_dir}/shinonome.cxx" => "#{dir}/gen_shinonome_data.rb" do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    Dir.chdir build_dir do
      ruby  t.prereqs.first
    end
  end
end
