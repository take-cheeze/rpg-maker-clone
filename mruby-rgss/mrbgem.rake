MRuby::Gem::Specification.new('mruby-rgss') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RGSS implementation in mruby'

  # Color, Tone and Table provide RGSS-compatible Marshal (_dump/_load) support.
  add_dependency 'mruby-marshal'
  # The Bitmap loader tests write fixture images to disk and read them back with
  # File, so the standalone mrbtest build needs mruby-io. The loader itself
  # reads files through C stdio, so this is only needed for the tests.
  add_test_dependency 'mruby-io'

  cxx.include_paths <<
    "#{dir}/../3rd/uni-algo/include" <<
    "#{dir}/../3rd/lvgl" <<
    "#{dir}/../include" <<
    "#{dir}/../3rd/stb" <<
    build_dir
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/uni-algo" << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/lvgl/lib"
  linker.libraries << "uni-algo" << "lvgl" << "pthread"

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
